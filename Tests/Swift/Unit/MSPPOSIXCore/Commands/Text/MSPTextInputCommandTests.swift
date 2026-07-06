import Foundation
import XCTest
import MSPCore
import MSPPOSIXCore

final class MSPTextInputCommandTests: XCTestCase {
    func testCatReadsStandardInputAndConsumesDashOnce() async throws {
        let stdin = Data("stdin\n".utf8)

        let direct = await runCommand("cat", [], standardInput: stdin)
        let repeatedDash = await runCommand("cat", ["-", "-"], standardInput: stdin)

        XCTAssertEqual(direct.stdout, "stdin\n")
        XCTAssertEqual(repeatedDash.stdout, "stdin\n")
    }

    func testCatMatchesGNUCoreutilsVisibleOutputOptions() async throws {
        let showEnds = await runCommand("cat", ["-E"], standardInput: Data("a\nb".utf8))
        let showTabs = await runCommand("cat", ["-T"], standardInput: Data("a\tb\n".utf8))
        let showAll = await runCommand("cat", ["-A"], standardInput: Data("a\tb\n\n".utf8))
        let number = await runCommand("cat", ["-n"], standardInput: Data("a\n\nb\n".utf8))
        let numberNonblank = await runCommand("cat", ["-b"], standardInput: Data("a\n\nb\n".utf8))
        let squeeze = await runCommand("cat", ["-s"], standardInput: Data("a\n\n\n\nb\n".utf8))
        let combined = await runCommand("cat", ["-A", "-n", "-s"], standardInput: Data("a\t\n\n\nB".utf8))
        let control = await runCommand("cat", ["-v"], standardInput: Data([0, 1, 7, 8, 11, 12, 13, 127]))
        let meta = await runCommand("cat", ["-v"], standardInput: Data([128, 129, 159, 160, 255]))
        let lowerE = await runCommand("cat", ["-e"], standardInput: Data("x\n".utf8))
        let lowerT = await runCommand("cat", ["-t"], standardInput: Data("x\t\n".utf8))
        let showEndsKeepsInvalidByte = await runCommand("cat", ["-E"], standardInput: Data([0xFF, 0x0A]))
        let showTabsKeepsInvalidByte = await runCommand("cat", ["-T"], standardInput: Data([0xFF, 0x09, 0x41]))

        XCTAssertEqual(showEnds.stdout, "a$\nb")
        XCTAssertEqual(showTabs.stdout, "a^Ib\n")
        XCTAssertEqual(showAll.stdout, "a^Ib$\n$\n")
        XCTAssertEqual(number.stdout, "     1\ta\n     2\t\n     3\tb\n")
        XCTAssertEqual(numberNonblank.stdout, "     1\ta\n\n     2\tb\n")
        XCTAssertEqual(squeeze.stdout, "a\n\nb\n")
        XCTAssertEqual(combined.stdout, "     1\ta^I$\n     2\t$\n     3\tB")
        XCTAssertEqual(control.stdout, "^@^A^G^H^K^L^M^?")
        XCTAssertEqual(meta.stdout, "M-^@M-^AM-^_M- M-^?")
        XCTAssertEqual(lowerE.stdout, "x$\n")
        XCTAssertEqual(lowerT.stdout, "x^I\n")
        XCTAssertEqual(showEndsKeepsInvalidByte.stdoutData, Data([0xFF, 0x24, 0x0A]))
        XCTAssertEqual(showTabsKeepsInvalidByte.stdoutData, Data([0xFF]) + Data("^IA".utf8))
    }

    func testCatCarriesNumberingAndSqueezeStateAcrossFiles() async throws {
        let workspace = TextWorkspace(files: [
            "/tmp/first.txt": Data("a\n\n".utf8),
            "/tmp/second.txt": Data("\nb\n".utf8)
        ])

        let numbered = await runCommand(
            "cat",
            ["-n", "-s", "/tmp/first.txt", "/tmp/second.txt"],
            workspace: workspace
        )
        let squeezed = await runCommand(
            "cat",
            ["-s", "/tmp/first.txt", "/tmp/second.txt"],
            workspace: workspace
        )

        XCTAssertEqual(numbered.stdout, "     1\ta\n     2\t\n     3\tb\n")
        XCTAssertEqual(squeezed.stdout, "a\n\nb\n")
    }

    func testWcSupportsStandardInputDashAndTotals() async throws {
        let workspace = TextWorkspace(files: [
            "/tmp/a.txt": Data("file\n".utf8)
        ])

        let stdinMultiColumn = await runCommand(
            "wc",
            ["-l", "-w", "-c"],
            standardInput: Data("a\n".utf8)
        )
        let stdinByteOnly = await runCommand(
            "wc",
            ["-c"],
            standardInput: Data("one two\n".utf8)
        )
        let dashByteOnly = await runCommand(
            "wc",
            ["-c", "-"],
            standardInput: Data("one two\n".utf8)
        )
        let mixed = await runCommand(
            "wc",
            ["-c", "/tmp/a.txt", "-", "/tmp/a.txt"],
            workspace: workspace,
            standardInput: Data("stdin\n".utf8)
        )

        XCTAssertEqual(stdinMultiColumn.stdout, "      1       1       2\n")
        XCTAssertEqual(stdinByteOnly.stdout, "8\n")
        XCTAssertEqual(dashByteOnly.stdout, "8 -\n")
        XCTAssertEqual(
            mixed.stdout,
            "      5 /tmp/a.txt\n      6 -\n      5 /tmp/a.txt\n     16 total\n"
        )
    }

    func testHeadAndTailSupportGNUSelectionOptions() async throws {
        let workspace = TextWorkspace(files: [
            "/downloads/alpha.txt": Data("one\nTWO\nthree\nfour\n".utf8),
            "/downloads/beta.txt": Data("abcXYZ\n".utf8)
        ])

        let headSigned = await runCommand("head", ["-n", "-1", "/downloads/alpha.txt"], workspace: workspace)
        let headHeaders = await runCommand("head", ["-v", "-n1", "/downloads/alpha.txt"], workspace: workspace)
        let headQuiet = await runCommand(
            "head",
            ["-q", "-n1", "/downloads/alpha.txt", "/downloads/beta.txt"],
            workspace: workspace
        )
        let tailFromLine = await runCommand("tail", ["-n", "+3", "/downloads/alpha.txt"], workspace: workspace)
        let tailBytes = await runCommand("tail", ["-c", "+4", "/downloads/beta.txt"], workspace: workspace)
        let headAllButBytes = await runCommand("head", ["-c", "-2", "/downloads/beta.txt"], workspace: workspace)
        let headByteSuffix = await runCommand("head", ["-c", "1K"], standardInput: Data(repeating: 0x78, count: 1_025))
        let tailByteSuffix = await runCommand("tail", ["-c", "1KB"], standardInput: Data(repeating: 0x79, count: 1_001))
        let headMissing = await runCommand("head", ["-n1", "missing", "/downloads/beta.txt"], workspace: workspace)
        let headZeroMissing = await runCommand("head", ["-n", "0", "missing"], workspace: workspace)
        let tailZeroRecords = await runCommand(
            "tail",
            ["-z", "-n", "+2"],
            standardInput: Data([0x61, 0x00, 0x62, 0x00, 0x63])
        )
        let headZeroTerminatedObsolete = await runCommand(
            "head",
            ["-z", "-2"],
            standardInput: Data([0x61, 0x00, 0x62, 0x00, 0x63, 0x00])
        )
        let tailZeroTerminatedObsolete = await runCommand(
            "tail",
            ["-z", "+2"],
            standardInput: Data([0x61, 0x00, 0x62, 0x00, 0x63, 0x00])
        )
        let headOldQuiet = await runCommand(
            "head",
            ["-2q", "/downloads/alpha.txt", "/downloads/beta.txt"],
            workspace: workspace
        )
        let headOldBytes = await runCommand("head", ["-5c", "/downloads/beta.txt"], workspace: workspace)
        let tailOldFromStart = await runCommand("tail", ["+3", "/downloads/alpha.txt"], workspace: workspace)
        let tailOldBytes = await runCommand("tail", ["-3c", "/downloads/beta.txt"], workspace: workspace)

        XCTAssertEqual(headSigned.stdout, "one\nTWO\nthree\n")
        XCTAssertEqual(headHeaders.stdout, "==> /downloads/alpha.txt <==\none\n")
        XCTAssertEqual(headQuiet.stdout, "one\nabcXYZ\n")
        XCTAssertEqual(tailFromLine.stdout, "three\nfour\n")
        XCTAssertEqual(tailBytes.stdout, "XYZ\n")
        XCTAssertEqual(headAllButBytes.stdout, "abcXY")
        XCTAssertEqual(headByteSuffix.stdoutData.count, 1_024)
        XCTAssertEqual(tailByteSuffix.stdoutData.count, 1_000)
        XCTAssertEqual(headMissing.stdout, "==> /downloads/beta.txt <==\nabcXYZ\n")
        XCTAssertEqual(headMissing.stderr, "head: cannot open 'missing' for reading: No such file or directory\n")
        XCTAssertEqual(headMissing.exitCode, 1)
        XCTAssertEqual(headZeroMissing.stdout, "")
        XCTAssertEqual(headZeroMissing.stderr, "head: cannot open 'missing' for reading: No such file or directory\n")
        XCTAssertEqual(headZeroMissing.exitCode, 1)
        XCTAssertEqual(tailZeroRecords.stdout, "b\u{0}c")
        XCTAssertEqual(headZeroTerminatedObsolete.stdoutData, Data([0x61, 0x00, 0x62, 0x00]))
        XCTAssertEqual(tailZeroTerminatedObsolete.stdoutData, Data([0x62, 0x00, 0x63, 0x00]))
        XCTAssertEqual(headOldQuiet.stdout, "one\nTWO\nabcXYZ\n")
        XCTAssertEqual(headOldBytes.stdout, "abcXY")
        XCTAssertEqual(tailOldFromStart.stdout, "three\nfour\n")
        XCTAssertEqual(tailOldBytes.stdout, "YZ\n")
    }

    func testHeadAndTailHeaderSpacingStdinAndPolicyDiagnostics() async throws {
        let workspace = TextWorkspace(files: [
            "/tmp/a.txt": Data("a1\na2\n".utf8),
            "/tmp/b.txt": Data("b1\nb2\n".utf8)
        ])

        let headMixedStdin = await runCommand(
            "head",
            ["-n1", "/tmp/a.txt", "-", "-"],
            workspace: workspace,
            standardInput: Data("stdin1\nstdin2\n".utf8)
        )
        let tailMixedStdin = await runCommand(
            "tail",
            ["-n1", "/tmp/a.txt", "-", "/tmp/b.txt"],
            workspace: workspace,
            standardInput: Data("stdin1\nstdin2\n".utf8)
        )
        let badHeadOldSuffix = await runCommand("head", ["-2x"], standardInput: Data("a\n".utf8))
        let badTailOldContext = await runCommand("tail", ["-3x"], standardInput: Data("a\n".utf8))
        let tailFollowShort = await runCommand("tail", ["-f"], standardInput: Data("a\n".utf8))
        let tailFollowNameShort = await runCommand("tail", ["-F", "/tmp/a.txt"], workspace: workspace)
        let tailFollowLong = await runCommand("tail", ["--follow=name", "/tmp/a.txt"], workspace: workspace)
        let tailRetry = await runCommand("tail", ["--retry", "/tmp/a.txt"], workspace: workspace)
        let tailPid = await runCommand("tail", ["--pid=123", "/tmp/a.txt"], workspace: workspace)
        let tailSleep = await runCommand("tail", ["--sleep-interval=1", "/tmp/a.txt"], workspace: workspace)
        let tailMaxStats = await runCommand("tail", ["--max-unchanged-stats=2", "/tmp/a.txt"], workspace: workspace)

        XCTAssertEqual(
            headMixedStdin.stdout,
            "==> /tmp/a.txt <==\na1\n\n==> standard input <==\nstdin1\n\n==> standard input <==\n"
        )
        XCTAssertEqual(
            tailMixedStdin.stdout,
            "==> /tmp/a.txt <==\na2\n\n==> standard input <==\nstdin2\n\n==> /tmp/b.txt <==\nb2\n"
        )
        XCTAssertEqual(badHeadOldSuffix.stderr, "head: invalid trailing option -- x\n")
        XCTAssertEqual(badHeadOldSuffix.exitCode, 2)
        XCTAssertEqual(badTailOldContext.stderr, "tail: option used in invalid context -- 3\n")
        XCTAssertEqual(badTailOldContext.exitCode, 2)
        XCTAssertEqual(
            tailFollowShort.stderr,
            "tail: -f is disabled by MSP policy: follow mode requires long-lived file/process watching\n"
        )
        XCTAssertEqual(tailFollowShort.exitCode, 2)
        XCTAssertEqual(
            tailFollowNameShort.stderr,
            "tail: -F is disabled by MSP policy: follow mode requires long-lived file/process watching\n"
        )
        XCTAssertEqual(tailFollowNameShort.exitCode, 2)
        XCTAssertEqual(
            tailFollowLong.stderr,
            "tail: --follow is disabled by MSP policy: follow mode requires long-lived file/process watching\n"
        )
        XCTAssertEqual(tailFollowLong.exitCode, 2)
        XCTAssertEqual(
            tailRetry.stderr,
            "tail: --retry is disabled by MSP policy: follow mode requires long-lived file/process watching\n"
        )
        XCTAssertEqual(tailRetry.exitCode, 2)
        XCTAssertEqual(
            tailPid.stderr,
            "tail: --pid is disabled by MSP policy: follow mode requires long-lived file/process watching\n"
        )
        XCTAssertEqual(tailPid.exitCode, 2)
        XCTAssertEqual(
            tailSleep.stderr,
            "tail: --sleep-interval is disabled by MSP policy: follow mode requires long-lived file/process watching\n"
        )
        XCTAssertEqual(tailSleep.exitCode, 2)
        XCTAssertEqual(
            tailMaxStats.stderr,
            "tail: --max-unchanged-stats is disabled by MSP policy: follow mode requires long-lived file/process watching\n"
        )
        XCTAssertEqual(tailMaxStats.exitCode, 2)
    }

    func testHeadAndTailSupportHelpAndVersion() async throws {
        let headHelp = await runCommand("head", ["--help"])
        let headVersion = await runCommand("head", ["--version"])
        let tailHelp = await runCommand("tail", ["--help"])
        let tailVersion = await runCommand("tail", ["--version"])

        XCTAssertTrue(headHelp.stdout.hasPrefix("Usage: head [OPTION]... [FILE]..."))
        XCTAssertEqual(headHelp.stderr, "")
        XCTAssertEqual(headHelp.exitCode, 0)
        XCTAssertEqual(headVersion.stdout, "head (GNU coreutils) 9.1\n")
        XCTAssertEqual(headVersion.stderr, "")
        XCTAssertEqual(headVersion.exitCode, 0)
        XCTAssertTrue(tailHelp.stdout.hasPrefix("Usage: tail [OPTION]... [FILE]..."))
        XCTAssertEqual(tailHelp.stderr, "")
        XCTAssertEqual(tailHelp.exitCode, 0)
        XCTAssertEqual(tailVersion.stdout, "tail (GNU coreutils) 9.1\n")
        XCTAssertEqual(tailVersion.stderr, "")
        XCTAssertEqual(tailVersion.exitCode, 0)
    }

    func testWcCountsCharactersAndDisplayColumnsLikeGNUCoreutils() async throws {
        let wide = await runCommand("wc", ["-m", "-c", "-L"], standardInput: Data("中\n".utf8))
        let combining = await runCommand("wc", ["-m", "-c", "-L"], standardInput: Data("e\u{0301}\n".utf8))
        let tabbed = await runCommand("wc", ["-L"], standardInput: Data("a\tb\n".utf8))
        let nulBytes = await runCommand("wc", ["-l", "-w", "-m", "-c", "-L"], standardInput: Data([0x00, 0x41, 0x00, 0x0A]))
        let invalidUTF8 = await runCommand("wc", ["-m", "-w", "-c"], standardInput: Data([0xFF, 0x20, 0x41, 0x0A]))
        let veryLongLine = await runCommand(
            "wc",
            ["-L"],
            standardInput: Data(repeating: 0x61, count: 10_000) + Data("\n".utf8)
        )

        XCTAssertEqual(wide.stdout, "      2       4       2\n")
        XCTAssertEqual(combining.stdout, "      3       4       1\n")
        XCTAssertEqual(tabbed.stdout, "9\n")
        XCTAssertEqual(nulBytes.stdout, "      1       1       4       4       1\n")
        XCTAssertEqual(invalidUTF8.stdout, "      1       3       4\n")
        XCTAssertEqual(veryLongLine.stdout, "10000\n")
    }

    func testWcFiles0FromDebugAndStandardOptions() async throws {
        let workspace = TextWorkspace(files: [
            "/tmp/a.txt": Data("a\n".utf8),
            "/tmp/b.txt": Data("bb cc".utf8),
            "/tmp/list0": Data("/tmp/a.txt\0/tmp/b.txt\0".utf8)
        ])

        let listed = await runCommand(
            "wc",
            ["-l", "-w", "-c", "--files0-from=/tmp/list0"],
            workspace: workspace
        )
        let mixedError = await runCommand(
            "wc",
            ["--files0-from=/tmp/list0", "/tmp/a.txt"],
            workspace: workspace
        )
        let stdinDashError = await runCommand(
            "wc",
            ["--files0-from=-"],
            workspace: workspace,
            standardInput: Data("-\0".utf8)
        )
        let debug = await runCommand("wc", ["--debug", "-c"], standardInput: Data("abc".utf8))
        let help = await runCommand("wc", ["--help"])
        let version = await runCommand("wc", ["--version"])

        XCTAssertEqual(
            listed.stdout,
            "1 1 2 /tmp/a.txt\n0 2 5 /tmp/b.txt\n1 3 7 total\n"
        )
        XCTAssertEqual(
            mixedError.stderr,
            "wc: extra operand \u{2018}/tmp/a.txt\u{2019}\nfile operands cannot be combined with --files0-from\nTry 'wc --help' for more information.\n"
        )
        XCTAssertEqual(mixedError.exitCode, 1)
        XCTAssertEqual(
            stdinDashError.stderr,
            "wc: when reading file names from stdin, no file name of \u{2018}-\u{2019} allowed\n"
        )
        XCTAssertEqual(stdinDashError.exitCode, 1)
        XCTAssertEqual(debug.stdout, "3\n")
        XCTAssertEqual(debug.stderr, "")
        XCTAssertTrue(help.stdout.hasPrefix("Usage: wc [OPTION]... [FILE]..."))
        XCTAssertEqual(version.stdout, "wc (GNU coreutils) 9.1\n")
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

private struct TextWorkspace: MSPWorkspace {
    let rootPath = "/"
    let fileSystem: any MSPWorkspaceFileSystem

    init(files: [String: Data]) {
        self.fileSystem = TextWorkspaceFileSystem(files: files)
    }
}

private struct TextWorkspaceFileSystem: MSPWorkspaceFileSystem {
    let policy = MSPWorkspaceFileSystemPolicy.default
    var files: [String: Data]

    func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
        guard MSPWorkspacePathResolver.isSyntacticallyValid(path),
              MSPWorkspacePathResolver.isSyntacticallyValid(currentDirectory)
        else {
            throw MSPWorkspaceFileSystemError.invalidPath(path)
        }
        return MSPResolvedPath(
            virtualPath: MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
        )
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

    func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        throw MSPWorkspaceFileSystemError.notSymbolicLink(virtualPath)
    }

    func listDirectory(_ path: String, from currentDirectory: String) throws -> [MSPDirectoryEntry] {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "list")
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
