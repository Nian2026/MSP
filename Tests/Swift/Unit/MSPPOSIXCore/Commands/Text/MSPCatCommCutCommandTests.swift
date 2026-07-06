import Foundation
import XCTest
import MSPCore
import MSPPOSIXCore

final class MSPCatCommCutCommandTests: XCTestCase {
    func testCatSupportsGNUHelpVersionAndContinuesAfterMissingFiles() async throws {
        let workspace = CatCommCutWorkspace(files: [
            "/a.txt": Data("A\n".utf8),
            "/b.txt": Data("B\n".utf8)
        ])

        let help = await runCommand("cat", ["--help"])
        let version = await runCommand("cat", ["--version"])
        let mixed = await runCommand("cat", ["/a.txt", "missing", "/b.txt"], workspace: workspace)

        XCTAssertTrue(help.stdout.hasPrefix("Usage: cat [OPTION]... [FILE]...\n"))
        XCTAssertEqual(help.exitCode, 0)
        XCTAssertTrue(version.stdout.hasPrefix("cat (GNU coreutils) 9.1\n"))
        XCTAssertEqual(version.exitCode, 0)
        XCTAssertEqual(mixed.stdout, "A\nB\n")
        XCTAssertEqual(mixed.stderr, "cat: missing: No such file or directory\n")
        XCTAssertEqual(mixed.exitCode, 1)
    }

    func testCommSupportsGNUHelpVersionAndInputDiagnostics() async throws {
        let workspace = CatCommCutWorkspace(files: [
            "/left.txt": Data("a\nb\n".utf8),
            "/right.txt": Data("b\nc\n".utf8)
        ])

        let help = await runCommand("comm", ["--help"])
        let version = await runCommand("comm", ["--version"])
        let bothStdin = await runCommand("comm", ["-", "-"], standardInput: Data("a\n".utf8))
        let duplicateSameDelimiter = await runCommand(
            "comm",
            ["--output-delimiter=:", "--output-delimiter=:", "/left.txt", "/right.txt"],
            workspace: workspace
        )
        let duplicateDifferentDelimiter = await runCommand(
            "comm",
            ["--output-delimiter=:", "--output-delimiter=,", "/left.txt", "/right.txt"],
            workspace: workspace
        )

        XCTAssertTrue(help.stdout.hasPrefix("Usage: comm [OPTION]... FILE1 FILE2\n"))
        XCTAssertEqual(help.exitCode, 0)
        XCTAssertTrue(version.stdout.hasPrefix("comm (GNU coreutils) 9.1\n"))
        XCTAssertEqual(version.exitCode, 0)
        XCTAssertEqual(bothStdin.stderr, "comm: both files cannot be standard input\n")
        XCTAssertEqual(bothStdin.exitCode, 1)
        XCTAssertEqual(duplicateSameDelimiter.stdout, "a\n::b\n:c\n")
        XCTAssertEqual(duplicateSameDelimiter.exitCode, 0)
        XCTAssertEqual(duplicateDifferentDelimiter.stderr, "comm: multiple output delimiters specified\n")
        XCTAssertEqual(duplicateDifferentDelimiter.exitCode, 1)
    }

    func testCommDefaultOrderDiagnosticsFollowUnpairableAndTotalRules() async throws {
        let identicalUnsorted = CatCommCutWorkspace(files: [
            "/left.txt": Data("b\na\n".utf8),
            "/right.txt": Data("b\na\n".utf8)
        ])
        let unpairedUnsorted = CatCommCutWorkspace(files: [
            "/left.txt": Data("b\na\n".utf8),
            "/right.txt": Data("b\nc\n".utf8)
        ])

        let matching = await runCommand("comm", ["/left.txt", "/right.txt"], workspace: identicalUnsorted)
        let defaultFailureWithTotal = await runCommand(
            "comm",
            ["--total", "/left.txt", "/right.txt"],
            workspace: unpairedUnsorted
        )
        let explicitNoCheck = await runCommand(
            "comm",
            ["--nocheck-order", "--total", "/left.txt", "/right.txt"],
            workspace: unpairedUnsorted
        )
        let checkThenNoCheck = await runCommand(
            "comm",
            ["--check-order", "--nocheck-order", "/left.txt", "/right.txt"],
            workspace: unpairedUnsorted
        )
        let noCheckThenCheck = await runCommand(
            "comm",
            ["--nocheck-order", "--check-order", "/left.txt", "/right.txt"],
            workspace: unpairedUnsorted
        )

        XCTAssertEqual(matching.stdout, "\t\tb\n\t\ta\n")
        XCTAssertEqual(matching.stderr, "")
        XCTAssertEqual(matching.exitCode, 0)
        XCTAssertEqual(defaultFailureWithTotal.stdout, "\t\tb\na\n\tc\n1\t1\t1\ttotal\n")
        XCTAssertEqual(
            defaultFailureWithTotal.stderr,
            "comm: file 1 is not in sorted order\ncomm: input is not in sorted order\n"
        )
        XCTAssertEqual(defaultFailureWithTotal.exitCode, 1)
        XCTAssertEqual(explicitNoCheck.stdout, "\t\tb\na\n\tc\n1\t1\t1\ttotal\n")
        XCTAssertEqual(explicitNoCheck.stderr, "")
        XCTAssertEqual(explicitNoCheck.exitCode, 0)
        XCTAssertEqual(checkThenNoCheck.stdout, "\t\tb\na\n\tc\n")
        XCTAssertEqual(checkThenNoCheck.stderr, "")
        XCTAssertEqual(checkThenNoCheck.exitCode, 0)
        XCTAssertEqual(noCheckThenCheck.stdout, "\t\tb\n")
        XCTAssertEqual(noCheckThenCheck.stderr, "comm: file 1 is not in sorted order\n")
        XCTAssertEqual(noCheckThenCheck.exitCode, 1)
    }

    func testCommZeroTerminatedRecordsSupportMixedStdinAndFileOperands() async throws {
        let workspace = CatCommCutWorkspace(files: [
            "/right.bin": Data([0x62, 0x00, 0x63, 0x00, 0x64, 0x00])
        ])

        let common = await runCommand(
            "comm",
            ["-z", "-12", "-", "/right.bin"],
            workspace: workspace,
            standardInput: Data([0x61, 0x00, 0x62, 0x00, 0x64, 0x00])
        )

        XCTAssertEqual(common.stdoutData, Data([0x62, 0x00, 0x64, 0x00]))
        XCTAssertEqual(common.stderr, "")
        XCTAssertEqual(common.exitCode, 0)
    }

    func testCutSupportsGNUHelpVersionDiagnosticsAndNULRecords() async throws {
        let help = await runCommand("cut", ["--help"])
        let version = await runCommand("cut", ["--version"])
        let delimiterWithBytes = await runCommand("cut", ["-d", ":", "-b", "1"], standardInput: Data("a:b\n".utf8))
        let suppressWithCharacters = await runCommand("cut", ["-s", "-c", "1"], standardInput: Data("abc\n".utf8))
        let repeatedList = await runCommand("cut", ["-b", "1", "-b", "2"], standardInput: Data("abc\n".utf8))
        let nulRecords = await runCommand("cut", ["-z", "-b", "1"], standardInput: Data("ab\0cd".utf8))

        XCTAssertTrue(help.stdout.hasPrefix("Usage: cut OPTION... [FILE]...\n"))
        XCTAssertEqual(help.exitCode, 0)
        XCTAssertTrue(version.stdout.hasPrefix("cut (GNU coreutils) 9.1\n"))
        XCTAssertEqual(version.exitCode, 0)
        XCTAssertEqual(
            delimiterWithBytes.stderr,
            "cut: an input delimiter may be specified only when operating on fields\nTry 'cut --help' for more information.\n"
        )
        XCTAssertEqual(delimiterWithBytes.exitCode, 1)
        XCTAssertEqual(
            suppressWithCharacters.stderr,
            "cut: suppressing non-delimited lines makes sense\n\tonly when operating on fields\nTry 'cut --help' for more information.\n"
        )
        XCTAssertEqual(suppressWithCharacters.exitCode, 1)
        XCTAssertEqual(repeatedList.stderr, "cut: only one list may be specified\nTry 'cut --help' for more information.\n")
        XCTAssertEqual(repeatedList.exitCode, 1)
        XCTAssertEqual(nulRecords.stdoutData, Data("a\0c\0".utf8))
        XCTAssertEqual(nulRecords.exitCode, 0)
    }

    func testCutOutputDelimiterAppliesToByteAndCharacterRanges() async throws {
        let separatedBytes = await runCommand(
            "cut",
            ["--output-delimiter=:", "-b", "1,3"],
            standardInput: Data("abc\n".utf8)
        )
        let separatedByteRanges = await runCommand(
            "cut",
            ["--output-delimiter=:", "-b", "2-3,5"],
            standardInput: Data("abcdef\n".utf8)
        )
        let adjacentByteRanges = await runCommand(
            "cut",
            ["--output-delimiter=:", "-b", "1,2"],
            standardInput: Data("abc\n".utf8)
        )
        let complementedBytes = await runCommand(
            "cut",
            ["--complement", "--output-delimiter=:", "-b", "2-3"],
            standardInput: Data("abcde\n".utf8)
        )
        let separatedCharacters = await runCommand(
            "cut",
            ["--output-delimiter=:", "-c", "1,3"],
            standardInput: Data("abc\n".utf8)
        )

        XCTAssertEqual(separatedBytes.stdout, "a:c\n")
        XCTAssertEqual(separatedBytes.exitCode, 0)
        XCTAssertEqual(separatedByteRanges.stdout, "bc:e\n")
        XCTAssertEqual(separatedByteRanges.exitCode, 0)
        XCTAssertEqual(adjacentByteRanges.stdout, "a:b\n")
        XCTAssertEqual(adjacentByteRanges.exitCode, 0)
        XCTAssertEqual(complementedBytes.stdout, "a:de\n")
        XCTAssertEqual(complementedBytes.exitCode, 0)
        XCTAssertEqual(separatedCharacters.stdout, "a:c\n")
        XCTAssertEqual(separatedCharacters.exitCode, 0)
    }

    func testCutDelimiterOptionsUseRawArgumentBytesLikeGNUCoreutils() async throws {
        let escapedInputDelimiter = await runCommand(
            "cut",
            ["-d", "\\0", "-f", "1"],
            standardInput: Data("a\\0b\n".utf8)
        )
        let escapedOutputDelimiter = await runCommand(
            "cut",
            ["--output-delimiter=\\0", "-b", "1,3"],
            standardInput: Data("abc\n".utf8)
        )
        let blankSeparatedList = await runCommand(
            "cut",
            ["-b", "1 3"],
            standardInput: Data("abc\n".utf8)
        )

        XCTAssertEqual(
            escapedInputDelimiter.stderr,
            "cut: the delimiter must be a single character\nTry 'cut --help' for more information.\n"
        )
        XCTAssertEqual(escapedInputDelimiter.exitCode, 1)
        XCTAssertEqual(escapedOutputDelimiter.stdoutData, Data([0x61, 0x5c, 0x30, 0x63, 0x0a]))
        XCTAssertEqual(escapedOutputDelimiter.exitCode, 0)
        XCTAssertEqual(blankSeparatedList.stdout, "ac\n")
        XCTAssertEqual(blankSeparatedList.exitCode, 0)
    }

    func testCutListDiagnosticsFollowSetFieldsShape() async throws {
        let zeroByte = await runCommand("cut", ["-b", "0"], standardInput: Data("abc\n".utf8))
        let loneDash = await runCommand("cut", ["-b", "-"], standardInput: Data("abc\n".utf8))
        let decreasing = await runCommand("cut", ["-f", "3-1"], standardInput: Data("a:b:c\n".utf8))

        XCTAssertEqual(
            zeroByte.stderr,
            "cut: byte/character positions are numbered from 1\nTry 'cut --help' for more information.\n"
        )
        XCTAssertEqual(zeroByte.exitCode, 1)
        XCTAssertEqual(
            loneDash.stderr,
            "cut: invalid range with no endpoint: -\nTry 'cut --help' for more information.\n"
        )
        XCTAssertEqual(loneDash.exitCode, 1)
        XCTAssertEqual(
            decreasing.stderr,
            "cut: invalid decreasing range\nTry 'cut --help' for more information.\n"
        )
        XCTAssertEqual(decreasing.exitCode, 1)
    }

    func testCutCharacterModePreservesBytesLikeGNU91CutBytes() async throws {
        let invalidUTF8 = Data([0xC3, 0x28, 0x0A])
        let firstByte = await runCommand("cut", ["-c", "1"], standardInput: invalidUTF8)
        let secondByte = await runCommand("cut", ["-c", "2"], standardInput: invalidUTF8)
        let delimiterBetweenByteRanges = await runCommand(
            "cut",
            ["--output-delimiter=:", "-c", "1,2"],
            standardInput: invalidUTF8
        )

        XCTAssertEqual(firstByte.stdoutData, Data([0xC3, 0x0A]))
        XCTAssertEqual(firstByte.exitCode, 0)
        XCTAssertEqual(secondByte.stdoutData, Data([0x28, 0x0A]))
        XCTAssertEqual(secondByte.exitCode, 0)
        XCTAssertEqual(delimiterBetweenByteRanges.stdoutData, Data([0xC3, 0x3A, 0x28, 0x0A]))
        XCTAssertEqual(delimiterBetweenByteRanges.exitCode, 0)
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

private struct CatCommCutWorkspace: MSPWorkspace {
    let rootPath = "/"
    let fileSystem: any MSPWorkspaceFileSystem

    init(files: [String: Data]) {
        self.fileSystem = CatCommCutFileSystem(files: files)
    }
}

private struct CatCommCutFileSystem: MSPWorkspaceFileSystem {
    let policy = MSPWorkspaceFileSystemPolicy.default
    var files: [String: Data]

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
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        return data
    }

    func writeFile(_ path: String, data: Data, from currentDirectory: String, options: MSPFileWriteOptions) throws {
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

    func copy(_ sourcePath: String, to destinationPath: String, from currentDirectory: String, options: MSPFileCopyOptions) throws {
        throw MSPWorkspaceFileSystemError.io(path: sourcePath, operation: "copy")
    }

    func move(_ sourcePath: String, to destinationPath: String, from currentDirectory: String, options: MSPFileMoveOptions) throws {
        throw MSPWorkspaceFileSystemError.io(path: sourcePath, operation: "move")
    }
}
