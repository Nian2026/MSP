import Foundation
import XCTest
import MSPCore
import MSPPOSIXCore

final class MSPTextStreamOracleTests: XCTestCase {
    func testLinuxTextStreamOracleCases() async throws {
        let filesWorkspace = OracleTextWorkspace(files: [
            "/cat-number.txt": Data("a\n\n\nb\n".utf8),
            "/head-bytes.txt": Data("abcdef\n".utf8),
            "/tail-lines.txt": Data("1\n2\n3\n".utf8),
            "/wc-a.txt": Data("a\n".utf8),
            "/wc-b.txt": Data("bb cc".utf8),
            "/tac-a.txt": Data("a1\na2\n".utf8),
            "/tac-b.txt": Data("b1\nb2\n".utf8),
            "/paste-a.txt": Data("a\nb\n".utf8),
            "/paste-b.txt": Data("1\n2\n3\n".utf8),
            "/comm-left.txt": Data("a\nb\nc\n".utf8),
            "/comm-right.txt": Data("b\nc\nd\n".utf8),
            "/comm-unsorted-left.txt": Data("b\na\n".utf8),
            "/comm-unsorted-right.txt": Data("a\nb\n".utf8)
        ])

        await assertCommand("cat", [], stdin: "b\na\n", stdout: "b\na\n")
        await assertCommand(
            "cat",
            ["-n", "-s", "/cat-number.txt"],
            workspace: filesWorkspace,
            stdout: "     1\ta\n     2\t\n     3\tb\n"
        )
        await assertCommand(
            "cat",
            ["missing"],
            workspace: OracleTextWorkspace(),
            stderr: "cat: missing: No such file or directory\n",
            exitCode: 1
        )

        await assertCommand("head", ["-n", "2"], stdin: "1\n2\n3\n", stdout: "1\n2\n")
        await assertCommand(
            "head",
            ["-c", "-2", "/head-bytes.txt"],
            workspace: filesWorkspace,
            stdout: "abcde"
        )
        await assertCommand(
            "head",
            ["-n", "nope"],
            stderr: "head: invalid number of lines: \u{2018}nope\u{2019}\n",
            exitCode: 1
        )

        await assertCommand("tail", ["-n", "2"], stdin: "1\n2\n3\n", stdout: "2\n3\n")
        await assertCommand(
            "tail",
            ["-n", "+2", "/tail-lines.txt"],
            workspace: filesWorkspace,
            stdout: "2\n3\n"
        )
        await assertCommand(
            "tail",
            ["-c", "nope"],
            stderr: "tail: invalid number of bytes: \u{2018}nope\u{2019}\n",
            exitCode: 1
        )

        await assertCommand("wc", [], stdin: "one two\nx\n", stdout: "      2       3      10\n")
        await assertCommand(
            "wc",
            ["-l", "-w", "-c", "/wc-a.txt", "/wc-b.txt"],
            workspace: filesWorkspace,
            stdout: "1 1 2 /wc-a.txt\n0 2 5 /wc-b.txt\n1 3 7 total\n"
        )
        await assertCommand(
            "wc",
            ["-l", "/wc-a.txt", "/wc-b.txt"],
            workspace: filesWorkspace,
            stdout: "1 /wc-a.txt\n0 /wc-b.txt\n1 total\n"
        )
        await assertCommand(
            "wc",
            ["-c", "/wc-a.txt", "/wc-b.txt"],
            workspace: filesWorkspace,
            stdout: "2 /wc-a.txt\n5 /wc-b.txt\n7 total\n"
        )
        await assertCommand(
            "wc",
            ["missing"],
            workspace: OracleTextWorkspace(),
            stderr: "wc: missing: No such file or directory\n",
            exitCode: 1
        )

        await assertCommand("sort", [], stdin: "b\na\nc\n", stdout: "a\nb\nc\n")
        await assertCommand("sort", ["-n", "-u"], stdin: "2 b\n2 a\n1 c\n", stdout: "1 c\n2 b\n")
        await assertCommand(
            "sort",
            ["-c"],
            stdin: "b\na\n",
            stderr: "sort: -:2: disorder: a\n",
            exitCode: 1
        )

        await assertCommand("uniq", ["-c"], stdin: "a\na\nb\n", stdout: "      2 a\n      1 b\n")
        await assertCommand(
            "uniq",
            ["-f", "1"],
            stdin: "  1 same\tX\n2 same Y\n3 other Z\n",
            stdout: "  1 same\tX\n2 same Y\n3 other Z\n"
        )
        await assertCommand(
            "uniq",
            ["-w", "nope"],
            stderr: "uniq: nope: invalid number of bytes to compare\n",
            exitCode: 1
        )

        await assertCommand("tac", [], stdin: "1\n2\n3\n", stdout: "3\n2\n1\n")
        await assertCommand("tac", ["-s", ":"], stdin: "a:b:c", stdout: "cb:a:")
        await assertCommand("tac", ["-b", "-s", ":"], stdin: "a:b:c", stdout: ":c:ba")
        await assertCommand("tac", ["-r", "-s", "[0-9]+"], stdin: "a1b22c", stdout: "cb22a1")
        await assertCommand("tac", ["-b", "-r", "-s", "[0-9]+"], stdin: "a1b22c", stdout: "22c1ba")
        await assertCommand("tac", ["-s", ":"], stdin: "a:b:c:", stdout: "c:b:a:")
        await assertCommand(
            "tac",
            ["-r", "-s", ""],
            stdin: "a\n",
            stderr: "tac: separator cannot be empty\n",
            exitCode: 1
        )
        let tacHelp = await runCommand("tac", ["--help"], standardInput: Data())
        XCTAssertTrue(tacHelp.stdout.hasPrefix("Usage: tac [OPTION]... [FILE]..."))
        XCTAssertEqual(tacHelp.stderr, "")
        XCTAssertEqual(tacHelp.exitCode, 0)
        let tacVersion = await runCommand("tac", ["--version"], standardInput: Data())
        XCTAssertTrue(tacVersion.stdout.hasPrefix("tac (GNU coreutils) 9.1"))
        XCTAssertEqual(tacVersion.stderr, "")
        XCTAssertEqual(tacVersion.exitCode, 0)
        await assertCommand(
            "tac",
            ["/tac-a.txt", "/tac-b.txt"],
            workspace: filesWorkspace,
            stdout: "a2\na1\nb2\nb1\n"
        )
        await assertCommand(
            "tac",
            ["missing"],
            workspace: OracleTextWorkspace(),
            stderr: "tac: failed to open 'missing' for reading: No such file or directory\n",
            exitCode: 1
        )

        await assertCommand("tee", [], stdin: "x\n", stdout: "x\n")
        let teeHelp = await runCommand("tee", ["--help"], standardInput: Data())
        XCTAssertTrue(teeHelp.stdout.hasPrefix("Usage: tee [OPTION]... [FILE]..."))
        XCTAssertEqual(teeHelp.stderr, "")
        XCTAssertEqual(teeHelp.exitCode, 0)
        let teeVersion = await runCommand("tee", ["--version"], standardInput: Data())
        XCTAssertEqual(teeVersion.stdout, "tee (GNU coreutils) 9.1\n")
        XCTAssertEqual(teeVersion.stderr, "")
        XCTAssertEqual(teeVersion.exitCode, 0)
        await assertCommand("tee", ["-p"], stdin: "x\n", stdout: "x\n")
        await assertCommand(
            "tee",
            ["--output-error=warn", "/dir"],
            workspace: OracleTextWorkspace(fileSystem: OracleTextFileSystem(directories: ["/dir"])),
            stdin: "x",
            stdout: "x",
            stderr: "tee: /dir: Is a directory\n",
            exitCode: 1
        )
        await assertCommand(
            "tee",
            ["--output-error=bad"],
            stdin: "x",
            stderr: """
            tee: invalid argument \u{2018}bad\u{2019} for \u{2018}--output-error\u{2019}
            Valid arguments are:
              - \u{2018}warn\u{2019}
              - \u{2018}warn-nopipe\u{2019}
              - \u{2018}exit\u{2019}
              - \u{2018}exit-nopipe\u{2019}
            Try 'tee --help' for more information.

            """,
            exitCode: 1
        )
        let teeFileSystem = OracleTextFileSystem(files: ["/tee.txt": Data("old\n".utf8)])
        let teeWorkspace = OracleTextWorkspace(fileSystem: teeFileSystem)
        await assertCommand("tee", ["-a", "/tee.txt"], workspace: teeWorkspace, stdin: "new\n", stdout: "new\n")
        XCTAssertEqual(teeFileSystem.files["/tee.txt"], Data("old\nnew\n".utf8))
        await assertCommand(
            "tee",
            ["/dir"],
            workspace: OracleTextWorkspace(fileSystem: OracleTextFileSystem(directories: ["/dir"])),
            stdin: "x",
            stdout: "x",
            stderr: "tee: /dir: Is a directory\n",
            exitCode: 1
        )
        let teeContinueFileSystem = OracleTextFileSystem(directories: ["/dir"])
        await assertCommand(
            "tee",
            ["/dir", "/ok"],
            workspace: OracleTextWorkspace(fileSystem: teeContinueFileSystem),
            stdin: "x",
            stdout: "x",
            stderr: "tee: /dir: Is a directory\n",
            exitCode: 1
        )
        XCTAssertEqual(teeContinueFileSystem.files["/ok"], Data("x".utf8))
        let teeExitFileSystem = OracleTextFileSystem(directories: ["/dir"])
        await assertCommand(
            "tee",
            ["--output-error=exit", "/dir", "/skipped"],
            workspace: OracleTextWorkspace(fileSystem: teeExitFileSystem),
            stdin: "x",
            stderr: "tee: /dir: Is a directory\n",
            exitCode: 1
        )
        XCTAssertNil(teeExitFileSystem.files["/skipped"])
        let teeBinaryFileSystem = OracleTextFileSystem()
        await assertCommand(
            "tee",
            ["/bin"],
            workspace: OracleTextWorkspace(fileSystem: teeBinaryFileSystem),
            stdin: Data([0xff, 0x00, 0x41]),
            stdoutData: Data([0xff, 0x00, 0x41])
        )
        XCTAssertEqual(teeBinaryFileSystem.files["/bin"], Data([0xff, 0x00, 0x41]))
        let teeDashFileSystem = OracleTextFileSystem()
        await assertCommand(
            "tee",
            ["-"],
            workspace: OracleTextWorkspace(fileSystem: teeDashFileSystem),
            stdin: "dash",
            stdout: "dash"
        )
        XCTAssertEqual(teeDashFileSystem.files["/-"], Data("dash".utf8))

        let nlBoundaryWorkspace = OracleTextWorkspace(files: [
            "/first": Data("a".utf8),
            "/second": Data("b\n".utf8)
        ])
        await assertCommand(
            "nl",
            ["-ba", "/first", "/second"],
            workspace: nlBoundaryWorkspace,
            stdout: "     1\ta     2\tb\n"
        )

        await assertCommand("tr", ["a-z", "A-Z"], stdin: "abc 123\n", stdout: "ABC 123\n")
        await assertCommand("tr", ["-t", "abc", "xy"], stdin: "abc cab\n", stdout: "xyc cxy\n")
        await assertCommand("tr", ["-d", "-s", "ab", "X"], stdin: "aabbcc", stdout: "cc")
        await assertCommand(
            "tr",
            ["a-z"],
            stderr: "tr: missing operand after \u{2018}a-z\u{2019}\nTwo strings must be given when translating.\nTry 'tr --help' for more information.\n",
            exitCode: 1
        )

        await assertCommand("paste", ["-s", "-d", ",", "-"], stdin: "a\nb\n", stdout: "a,b\n")
        let pasteHelp = await runCommand("paste", ["--help"], standardInput: Data())
        XCTAssertTrue(pasteHelp.stdout.hasPrefix("Usage: paste [OPTION]... [FILE]..."))
        XCTAssertEqual(pasteHelp.stderr, "")
        XCTAssertEqual(pasteHelp.exitCode, 0)
        let pasteVersion = await runCommand("paste", ["--version"], standardInput: Data())
        XCTAssertEqual(pasteVersion.stdout, "paste (GNU coreutils) 9.1\n")
        XCTAssertEqual(pasteVersion.stderr, "")
        XCTAssertEqual(pasteVersion.exitCode, 0)
        await assertCommand("paste", ["-s", "-d", ""], stdin: "a\nb\n", stdout: "ab\n")
        await assertCommand(
            "paste",
            ["-s", "-d", "\\b\\f\\r\\v\\\\"],
            stdin: Data("a\nb\nc\nd\ne\nf\n".utf8),
            stdoutData: Data([0x61, 0x08, 0x62, 0x0C, 0x63, 0x0D, 0x64, 0x0B, 0x65, 0x5C, 0x66, 0x0A])
        )
        await assertCommand(
            "paste",
            ["-d", "\\"],
            stdin: "a\n",
            stderr: "paste: delimiter list ends with an unescaped backslash: \\\n",
            exitCode: 1
        )
        await assertCommand(
            "paste",
            ["-z", "-s", "-d", ","],
            stdin: Data("a\0b\0".utf8),
            stdoutData: Data("a,b\0".utf8)
        )
        await assertCommand(
            "paste",
            ["-d", ",", "/paste-a.txt", "/paste-b.txt"],
            workspace: filesWorkspace,
            stdout: "a,1\nb,2\n,3\n"
        )
        await assertCommand(
            "paste",
            ["missing"],
            workspace: OracleTextWorkspace(),
            stderr: "paste: missing: No such file or directory\n",
            exitCode: 1
        )

        await assertCommand(
            "comm",
            ["/comm-left.txt", "/comm-right.txt"],
            workspace: filesWorkspace,
            stdout: "a\n\t\tb\n\t\tc\n\td\n"
        )
        await assertCommand(
            "comm",
            ["-12", "/comm-left.txt", "/comm-right.txt"],
            workspace: filesWorkspace,
            stdout: "b\nc\n"
        )
        await assertCommand(
            "comm",
            ["--total", "/comm-left.txt", "/comm-right.txt"],
            workspace: filesWorkspace,
            stdout: "a\n\t\tb\n\t\tc\n\td\n1\t1\t2\ttotal\n"
        )
        var commNULTotalOutput = Data("a\n".utf8)
        commNULTotalOutput.append(contentsOf: [0, 0])
        commNULTotalOutput.append(Data("b\n".utf8))
        commNULTotalOutput.append(contentsOf: [0, 0])
        commNULTotalOutput.append(Data("c\n".utf8))
        commNULTotalOutput.append(0)
        commNULTotalOutput.append(Data("d\n1".utf8))
        commNULTotalOutput.append(0)
        commNULTotalOutput.append(Data("1".utf8))
        commNULTotalOutput.append(0)
        commNULTotalOutput.append(Data("2".utf8))
        commNULTotalOutput.append(0)
        commNULTotalOutput.append(Data("total\n".utf8))
        await assertCommand(
            "comm",
            ["--output-delimiter=", "--total", "/comm-left.txt", "/comm-right.txt"],
            workspace: filesWorkspace,
            stdoutData: commNULTotalOutput
        )
        await assertCommand(
            "comm",
            ["/comm-unsorted-left.txt", "/comm-unsorted-right.txt"],
            workspace: filesWorkspace,
            stdout: "\ta\n\t\tb\na\n",
            stderr: "comm: file 1 is not in sorted order\ncomm: input is not in sorted order\n",
            exitCode: 1
        )
        await assertCommand(
            "comm",
            ["--check-order", "/comm-unsorted-left.txt", "/comm-unsorted-right.txt"],
            workspace: filesWorkspace,
            stdout: "\ta\n\t\tb\n",
            stderr: "comm: file 1 is not in sorted order\n",
            exitCode: 1
        )
        await assertCommand(
            "comm",
            ["missing", "/comm-right.txt"],
            workspace: filesWorkspace,
            stderr: "comm: missing: No such file or directory\n",
            exitCode: 1
        )
    }

    func testByteOrientedTextCommandsPreserveNonUTF8OutputBytes() async throws {
        await assertCommand("cat", [], stdin: Data([0xff, 0x41]), stdoutData: Data([0xff, 0x41]))
        await assertCommand("head", ["-c", "2"], stdin: Data([0xff, 0x41, 0x42, 0x43]), stdoutData: Data([0xff, 0x41]))
        await assertCommand("tail", ["-c", "2"], stdin: Data([0x41, 0x42, 0xff, 0x43]), stdoutData: Data([0xff, 0x43]))
        await assertCommand("tac", [], stdin: Data([0xff, 0x61, 0x0a, 0x42, 0x0a]), stdoutData: Data([0x42, 0x0a, 0xff, 0x61, 0x0a]))
        await assertCommand("tee", [], stdin: Data([0xff, 0x41]), stdoutData: Data([0xff, 0x41]))
        await assertCommand("paste", ["-s", "-d", "\\0"], stdin: Data([0xff, 0x0a, 0x41, 0x0a]), stdoutData: Data([0xff, 0x41, 0x0a]))
        await assertCommand("sort", [], stdin: Data([0xff, 0x62, 0x0a, 0x61, 0x0a]), stdoutData: Data([0x61, 0x0a, 0xff, 0x62, 0x0a]))
        await assertCommand("uniq", [], stdin: Data([0xff, 0x61, 0x0a, 0xff, 0x61, 0x0a]), stdoutData: Data([0xff, 0x61, 0x0a]))

        let workspace = OracleTextWorkspace(files: [
            "/left.bin": Data([0xff, 0x61, 0x0a]),
            "/right.bin": Data([0xff, 0x61, 0x0a])
        ])
        await assertCommand(
            "comm",
            ["/left.bin", "/right.bin"],
            workspace: workspace,
            stdoutData: Data([0x09, 0x09, 0xff, 0x61, 0x0a])
        )
    }

    private func assertCommand(
        _ name: String,
        _ arguments: [String],
        workspace: (any MSPWorkspace)? = nil,
        stdin: String = "",
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32 = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await assertCommand(
            name,
            arguments,
            workspace: workspace,
            stdin: Data(stdin.utf8),
            stdoutData: Data(stdout.utf8),
            stderrData: Data(stderr.utf8),
            exitCode: exitCode,
            file: file,
            line: line
        )
    }

    private func assertCommand(
        _ name: String,
        _ arguments: [String],
        workspace: (any MSPWorkspace)? = nil,
        stdin: Data = Data(),
        stdoutData: Data,
        stderrData: Data = Data(),
        exitCode: Int32 = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let result = await runCommand(name, arguments, workspace: workspace, standardInput: stdin)

        XCTAssertEqual(result.stdoutData, stdoutData, "stdout mismatch for \(name) \(arguments)", file: file, line: line)
        XCTAssertEqual(result.stderrData, stderrData, "stderr mismatch for \(name) \(arguments)", file: file, line: line)
        XCTAssertEqual(result.exitCode, exitCode, "exit code mismatch for \(name) \(arguments)", file: file, line: line)
    }

    private func runCommand(
        _ name: String,
        _ arguments: [String],
        workspace: (any MSPWorkspace)? = nil,
        standardInput: Data = Data()
    ) async -> MSPCommandResult {
        let registry = try! MSPCommandRegistry()
        try! MSPPOSIXCoreCommandPack().registerCommands(into: registry)
        let executor = MSPCommandExecutor(registry: registry)
        return await executor.run(
            invocation: MSPCommandInvocation(name: name, arguments: arguments),
            context: MSPCommandContext(workspace: workspace, standardInput: standardInput)
        )
    }
}

private final class OracleTextWorkspace: MSPWorkspace, @unchecked Sendable {
    let rootPath = "/"
    let oracleFileSystem: OracleTextFileSystem
    var fileSystem: any MSPWorkspaceFileSystem { oracleFileSystem }

    init(files: [String: Data] = [:], directories: Set<String> = []) {
        self.oracleFileSystem = OracleTextFileSystem(files: files, directories: directories)
    }

    init(fileSystem: OracleTextFileSystem) {
        self.oracleFileSystem = fileSystem
    }
}

private final class OracleTextFileSystem: MSPWorkspaceFileSystem, @unchecked Sendable {
    let policy = MSPWorkspaceFileSystemPolicy.default
    var files: [String: Data]
    var directories: Set<String>

    init(files: [String: Data] = [:], directories: Set<String> = []) {
        self.files = files
        self.directories = directories.union(["/"])
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
        if files[virtualPath] != nil {
            return MSPFileInfo(virtualPath: virtualPath, type: .regularFile)
        }
        if directories.contains(virtualPath) || files.keys.contains(where: { $0.hasPrefix(virtualPath + "/") }) {
            return MSPFileInfo(virtualPath: virtualPath, type: .directory)
        }
        throw MSPWorkspaceFileSystemError.notFound(virtualPath)
    }

    func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        throw MSPWorkspaceFileSystemError.notSymbolicLink(virtualPath)
    }

    func listDirectory(_ path: String, from currentDirectory: String) throws -> [MSPDirectoryEntry] {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "list")
    }

    func readFile(_ path: String, from currentDirectory: String) throws -> Data {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        if directories.contains(virtualPath) {
            throw MSPWorkspaceFileSystemError.isDirectory(virtualPath)
        }
        guard let data = files[virtualPath] else {
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
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        if directories.contains(virtualPath) {
            throw MSPWorkspaceFileSystemError.isDirectory(virtualPath)
        }
        files[virtualPath] = data
    }

    func createDirectory(_ path: String, from currentDirectory: String, intermediates: Bool) throws {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        directories.insert(virtualPath)
    }

    func touch(_ path: String, from currentDirectory: String) throws {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        files[virtualPath] = files[virtualPath] ?? Data()
    }

    func remove(_ path: String, from currentDirectory: String, recursive: Bool) throws {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        files.removeValue(forKey: virtualPath)
        directories.remove(virtualPath)
    }

    func copy(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileCopyOptions
    ) throws {
        let source = try readFile(sourcePath, from: currentDirectory)
        try writeFile(destinationPath, data: source, from: currentDirectory, options: [.overwriteExisting])
    }

    func move(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileMoveOptions
    ) throws {
        let source = try readFile(sourcePath, from: currentDirectory)
        try writeFile(destinationPath, data: source, from: currentDirectory, options: [.overwriteExisting])
        try remove(sourcePath, from: currentDirectory, recursive: false)
    }
}
