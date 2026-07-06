import Foundation
import XCTest
import MSPCore
import MSPPOSIXCore

final class MSPTextLayoutCommandTests: XCTestCase {
    func testExprMatchesCore100OracleExamples() async throws {
        await assertCommand(MSPExprCommand(), ["1", "+", "2"], stdout: "3\n")
        await assertCommand(MSPExprCommand(), ["2", "*", "3"], stdout: "6\n")
        await assertCommand(MSPExprCommand(), ["5", ">", "3"], stdout: "1\n")
        await assertCommand(MSPExprCommand(), ["1", ">", "3"], stdout: "0\n", exitCode: 1)
        await assertCommand(MSPExprCommand(), ["length", "abc"], stdout: "3\n")
        await assertCommand(MSPExprCommand(), ["substr", "abcdef", "2", "3"], stdout: "bcd\n")
        await assertCommand(MSPExprCommand(), ["index", "abcdef", "de"], stdout: "4\n")
        await assertCommand(MSPExprCommand(), ["abc123", ":", #"abc\([0-9]*\)"#], stdout: "123\n")
        await assertCommand(MSPExprCommand(), ["abc", ":", "z"], stdout: "0\n", exitCode: 1)
        await assertCommand(
            MSPExprCommand(),
            ["1", "+"],
            stderr: "expr: syntax error: missing argument after \u{2018}+\u{2019}\n",
            exitCode: 2
        )
        await assertCommand(MSPExprCommand(), ["7", "/", "2"], stdout: "3\n")
        await assertCommand(MSPExprCommand(), ["7", "%", "2"], stdout: "1\n")
        await assertCommand(MSPExprCommand(), ["", "|", "fallback"], stdout: "fallback\n")
        await assertCommand(MSPExprCommand(), ["value", "&", "other"], stdout: "value\n")
        await assertCommand(MSPExprCommand(), ["(", "1", "+", "2", ")", "*", "3"], stdout: "9\n")
        await assertCommand(MSPExprCommand(), ["-1", "+", "2"], stdout: "1\n")
    }

    func testStringsMatchesBinaryAndOffsetOracleExamples() async throws {
        let workspace = TextLayoutWorkspace(files: [
            "/bin.dat": Data([0, 0]) + Data("abcd".utf8) + Data([0]),
            "/long.dat": Data([0]) + Data("abcde".utf8) + Data([0]) + Data("xy".utf8) + Data([0]) + Data("longer-string".utf8) + Data([0]),
            "/utf16.dat": Data("hello".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }),
            "/utf16be.dat": Data("HELLO".utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }),
            "/eight.dat": Data([0x80, 0x81]) + Data("AB".utf8) + Data([0]),
            "/utf32le.dat": Data([0x57, 0, 0, 0, 0x49, 0, 0, 0, 0x44, 0, 0, 0, 0x45, 0, 0, 0]),
            "/utf32be.dat": Data([0, 0, 0, 0x57, 0, 0, 0, 0x49, 0, 0, 0, 0x44, 0, 0, 0, 0x45]),
            "/white.dat": Data([0]) + Data("ab\ncd".utf8) + Data([0]),
            "/a b": Data("hello\0".utf8)
        ])
        await assertCommand(MSPStringsCommand(), ["long.dat"], workspace: workspace, stdout: "abcde\nlonger-string\n")
        await assertCommand(MSPStringsCommand(), ["-n", "5", "long.dat"], workspace: workspace, stdout: "abcde\nlonger-string\n")
        await assertCommand(MSPStringsCommand(), ["-5", "long.dat"], workspace: workspace, stdout: "abcde\nlonger-string\n")
        await assertCommand(MSPStringsCommand(), ["-f", "long.dat"], workspace: workspace, stdout: "long.dat: abcde\nlong.dat: longer-string\n")
        await assertCommand(MSPStringsCommand(), ["-w", "white.dat"], workspace: workspace, stdout: "ab\ncd\n")
        await assertCommand(MSPStringsCommand(), ["-s", "|", "long.dat"], workspace: workspace, stdout: "abcde|longer-string|")
        await assertCommand(MSPStringsCommand(), ["-t", "d", "bin.dat"], workspace: workspace, stdout: "      2 abcd\n")
        await assertCommand(MSPStringsCommand(), ["-t", "x", "bin.dat"], workspace: workspace, stdout: "      2 abcd\n")
        await assertCommand(MSPStringsCommand(), [], stdin: Data("\0hello\0".utf8), stdout: "hello\n")
        await assertCommand(MSPStringsCommand(), ["-e", "l", "utf16.dat"], workspace: workspace, stdout: "hello\n")
        await assertCommand(MSPStringsCommand(), ["-e", "b", "utf16be.dat"], workspace: workspace, stdout: "HELLO\n")
        await assertCommand(MSPStringsCommand(), ["-e", "S", "eight.dat"], workspace: workspace, stdoutData: Data([0x80, 0x81, 0x41, 0x42, 0x0A]))
        await assertCommand(MSPStringsCommand(), ["-e", "L", "utf32le.dat"], workspace: workspace, stdout: "WIDE\n")
        await assertCommand(MSPStringsCommand(), ["-e", "B", "utf32be.dat"], workspace: workspace, stdout: "WIDE\n")
        await assertCommand(MSPStringsCommand(), ["a b"], workspace: workspace, stdout: "hello\n")
        let help = await runCommand(MSPStringsCommand(), ["--help"], workspace: workspace)
        XCTAssertTrue(help.stdout.hasPrefix("Usage: strings"))
        XCTAssertEqual(help.exitCode, 0)
        await assertCommand(
            MSPStringsCommand(),
            ["missing"],
            workspace: workspace,
            stderr: "strings: 'missing': No such file\n",
            exitCode: 1
        )
        let invalid = await runCommand(MSPStringsCommand(), ["-Z", "bin.dat"], workspace: workspace)
        XCTAssertTrue(invalid.stderr.hasPrefix("strings: invalid option -- 'Z'\nUsage: strings [option(s)] [file(s)]\n"))
        XCTAssertEqual(invalid.exitCode, 1)
        await assertCommand(
            MSPStringsCommand(),
            ["-e", "Z", "bin.dat"],
            workspace: workspace,
            stderr: "strings: invalid encoding\n",
            exitCode: 1
        )
    }

    func testFoldPreservesByteLevelWrapping() async throws {
        let workspace = TextLayoutWorkspace(files: [
            "/in.txt": Data("abcdef\n".utf8),
            "/a": Data("abc".utf8),
            "/b": Data("def".utf8),
            "/a b": Data("abcdef".utf8)
        ])
        await assertCommand(MSPFoldCommand(), [], stdin: Data("abcdefghij\n".utf8), stdout: "abcdefghij\n")
        await assertCommand(MSPFoldCommand(), ["-w", "3"], stdin: Data("abcdef\n".utf8), stdout: "abc\ndef\n")
        await assertCommand(MSPFoldCommand(), ["-s", "-w", "5"], stdin: Data("aa bb cc\n".utf8), stdout: "aa \nbb cc\n")
        await assertCommand(
            MSPFoldCommand(),
            ["-b", "-w", "3"],
            stdin: Data("ééé\n".utf8),
            stdoutData: Data([0xC3, 0xA9, 0xC3, 0x0A, 0xA9, 0xC3, 0xA9, 0x0A])
        )
        await assertCommand(MSPFoldCommand(), ["-w", "2", "in.txt"], workspace: workspace, stdout: "ab\ncd\nef\n")
        await assertCommand(MSPFoldCommand(), ["-w", "2", "a", "b"], workspace: workspace, stdout: "ab\ncde\nf")
        await assertCommand(MSPFoldCommand(), ["-3"], stdin: Data("abcdef\n".utf8), stdout: "abc\ndef\n")
        await assertCommand(MSPFoldCommand(), ["-w", "4"], stdin: Data("ab\rcdef\n".utf8), stdout: "ab\rcdef\n")
        await assertCommand(MSPFoldCommand(), ["-w", "3"], stdin: Data([0x61, 0x62, 0x08, 0x63, 0x64, 0x0A]), stdoutData: Data([0x61, 0x62, 0x08, 0x63, 0x64, 0x0A]))
        await assertCommand(
            MSPFoldCommand(),
            ["-w", "nope"],
            stderr: "fold: invalid number of columns: \u{2018}nope\u{2019}\n",
            exitCode: 1
        )
        await assertCommand(
            MSPFoldCommand(),
            ["missing"],
            workspace: workspace,
            stderr: "fold: missing: No such file or directory\n",
            exitCode: 1
        )
        await assertCommand(MSPFoldCommand(), ["-w", "3", "a b"], workspace: workspace, stdout: "abc\ndef")
    }

    func testExpandAndUnexpandTabStops() async throws {
        let workspace = TextLayoutWorkspace(files: [
            "/in.txt": Data("a\tb\n".utf8),
            "/a": Data("        x\n".utf8),
            "/b": Data("        y\n".utf8)
        ])
        await assertCommand(MSPExpandCommand(), [], stdin: Data("a\tb\n".utf8), stdout: "a       b\n")
        await assertCommand(MSPExpandCommand(), ["-t", "4"], stdin: Data("a\tb\tc\n".utf8), stdout: "a   b   c\n")
        await assertCommand(MSPExpandCommand(), ["-4"], stdin: Data("a\tb\n".utf8), stdout: "a   b\n")
        await assertCommand(MSPExpandCommand(), ["-t", "2,6"], stdin: Data("a\tb\tc\n".utf8), stdout: "a b   c\n")
        await assertCommand(MSPExpandCommand(), ["-2,6"], stdin: Data("a\tb\tc\n".utf8), stdout: "a b   c\n")
        await assertCommand(MSPExpandCommand(), ["-t", "2,/4"], stdin: Data("a\tb\tc\n".utf8), stdout: "a b c\n")
        await assertCommand(MSPExpandCommand(), ["-t", "2,+4"], stdin: Data("a\tb\tc\n".utf8), stdout: "a b   c\n")
        await assertCommand(MSPExpandCommand(), ["-t", "+4"], stdin: Data("a\tb\n".utf8), stdout: "a   b\n")
        await assertCommand(MSPExpandCommand(), ["-i", "-t", "4"], stdin: Data("\ta\tb\n".utf8), stdout: "    a\tb\n")
        await assertCommand(MSPExpandCommand(), ["-t", "4"], stdin: Data("ab\rc\td\n".utf8), stdout: "ab\rc    d\n")
        await assertCommand(MSPExpandCommand(), ["-t", "4"], stdin: Data([0xFF, 0x09, 0x41, 0x0A]), stdoutData: Data([0xFF, 0x20, 0x20, 0x20, 0x41, 0x0A]))
        await assertCommand(MSPExpandCommand(), ["in.txt"], workspace: workspace, stdout: "a       b\n")
        let hugeTabStop = String(repeating: "9", count: 40)
        await assertCommand(
            MSPExpandCommand(),
            ["-t", "nope"],
            stderr: "expand: tab size contains invalid character(s): \u{2018}nope\u{2019}\n",
            exitCode: 1
        )
        await assertCommand(
            MSPExpandCommand(),
            ["-t", "0"],
            stderr: "expand: tab size cannot be 0\n",
            exitCode: 1
        )
        await assertCommand(
            MSPExpandCommand(),
            ["-t", "1/2"],
            stderr: "expand: '/' specifier not at start of number: \u{2018}/2\u{2019}\n",
            exitCode: 1
        )
        await assertCommand(
            MSPExpandCommand(),
            ["-t", hugeTabStop],
            stderr: "expand: tab stop is too large \u{2018}\(hugeTabStop)\u{2019}\n",
            exitCode: 1
        )
        await assertCommand(
            MSPExpandCommand(),
            ["-t", "2,+4,8"],
            stderr: "expand: '+' specifier only allowed with the last value\n",
            exitCode: 1
        )

        await assertCommand(MSPUnexpandCommand(), [], stdin: Data("        x\n".utf8), stdout: "\tx\n")
        await assertCommand(MSPUnexpandCommand(), ["-a"], stdin: Data("a       b\n".utf8), stdout: "a\tb\n")
        await assertCommand(MSPUnexpandCommand(), ["-t", "4"], stdin: Data("    x\n".utf8), stdout: "\tx\n")
        await assertCommand(MSPUnexpandCommand(), ["-4"], stdin: Data("    x\n".utf8), stdout: "\tx\n")
        await assertCommand(MSPUnexpandCommand(), ["-a", "-t", "2,6"], stdin: Data("  a   b\n".utf8), stdout: "\ta\tb\n")
        await assertCommand(MSPUnexpandCommand(), ["-a", "-t", "2,+4"], stdin: Data("  a   b\n".utf8), stdout: "\ta\tb\n")
        await assertCommand(MSPUnexpandCommand(), ["-a", "-t", "+4"], stdin: Data("    x\n".utf8), stdout: "\tx\n")
        await assertCommand(MSPUnexpandCommand(), ["-a", "-t", "4"], stdin: Data("ab\rc   d\n".utf8), stdout: "ab\rc   d\n")
        await assertCommand(MSPUnexpandCommand(), ["-a", "-t", "4"], stdin: Data([0xFF, 0x20, 0x20, 0x20, 0x41, 0x0A]), stdoutData: Data([0xFF, 0x09, 0x41, 0x0A]))
        await assertCommand(MSPUnexpandCommand(), ["-t", "4", "--first-only"], stdin: Data("    a    b\n".utf8), stdout: "\ta    b\n")
        await assertCommand(MSPUnexpandCommand(), ["a", "b"], workspace: workspace, stdout: "\tx\n\ty\n")
        await assertCommand(
            MSPUnexpandCommand(),
            ["-t", "nope"],
            stderr: "unexpand: tab size contains invalid character(s): \u{2018}nope\u{2019}\n",
            exitCode: 1
        )
        await assertCommand(
            MSPUnexpandCommand(),
            ["-t", "2,+4,/8"],
            stderr: "unexpand: '/' specifier is mutually exclusive with '+'\n",
            exitCode: 1
        )
        await assertCommand(
            MSPUnexpandCommand(),
            ["-t", "1+2"],
            stderr: "unexpand: '+' specifier not at start of number: \u{2018}+2\u{2019}\n",
            exitCode: 1
        )

        let expandHelp = await runCommand(MSPExpandCommand(), ["--help"], workspace: workspace)
        XCTAssertTrue(expandHelp.stdout.hasPrefix("Usage: expand [OPTION]... [FILE]..."))
        let unexpandVersion = await runCommand(MSPUnexpandCommand(), ["--version"], workspace: workspace)
        XCTAssertEqual(unexpandVersion.stdout, "unexpand (GNU coreutils) 9.1\n")
    }

    func testFmtMatchesStableOracleCases() async throws {
        let workspace = TextLayoutWorkspace(files: [
            "/in.txt": Data("alpha beta gamma delta\n".utf8),
            "/a": Data("a b c\n".utf8),
            "/b": Data("d e f\n".utf8),
            "/a b": Data("alpha beta gamma\n".utf8)
        ])
        await assertCommand(
            MSPFmtCommand(),
            [],
            stdin: Data("alpha beta gamma delta epsilon zeta eta theta\n".utf8),
            stdout: "alpha beta gamma delta epsilon zeta eta theta\n"
        )
        let fmtHelp = await runCommand(MSPFmtCommand(), ["--help"], workspace: workspace)
        XCTAssertTrue(fmtHelp.stdout.hasPrefix("Usage: fmt [-WIDTH] [OPTION]... [FILE]...\n"))
        let fmtVersion = await runCommand(MSPFmtCommand(), ["--version"], workspace: workspace)
        XCTAssertEqual(fmtVersion.stdout, "fmt (GNU coreutils) 9.1\n")
        await assertCommand(MSPFmtCommand(), ["-w", "12"], stdin: Data("alpha beta gamma delta\n".utf8), stdout: "alpha beta\ngamma delta\n")
        await assertCommand(MSPFmtCommand(), ["-12"], stdin: Data("alpha beta gamma delta\n".utf8), stdout: "alpha beta\ngamma delta\n")
        await assertCommand(MSPFmtCommand(), ["-w", "20", "-g", "12"], stdin: Data("alpha beta gamma delta\n".utf8), stdout: "alpha beta\ngamma delta\n")
        await assertCommand(MSPFmtCommand(), ["-g", "90"], stdin: Data("alpha beta gamma delta\n".utf8), stdout: "alpha beta gamma delta\n")
        await assertCommand(MSPFmtCommand(), ["-g", "90", "-w", "100"], stdin: Data("alpha beta gamma delta\n".utf8), stdout: "alpha beta gamma delta\n")
        await assertCommand(MSPFmtCommand(), ["-t", "-w", "12"], stdin: Data("tagged line\n   follow words\n".utf8), stdout: "tagged line\n   follow\n   words\n")
        await assertCommand(MSPFmtCommand(), ["-s", "-w", "12"], stdin: Data("alpha beta gamma delta\n".utf8), stdout: "alpha beta\ngamma delta\n")
        await assertCommand(MSPFmtCommand(), ["-u"], stdin: Data("alpha.  beta?   gamma!\n".utf8), stdout: "alpha.  beta?  gamma!\n")
        await assertCommand(MSPFmtCommand(), ["-w", "5"], stdin: Data("a b c d\n\ne f g h\n".utf8), stdout: "a b\nc d\n\ne f\ng h\n")
        let longParagraph = Array(repeating: "word", count: 1_200).joined(separator: " ") + "\n"
        let longResult = await runCommand(MSPFmtCommand(), ["-w", "20"], workspace: workspace, standardInput: Data(longParagraph.utf8))
        XCTAssertEqual(longResult.exitCode, 0)
        XCTAssertEqual(longResult.stdout.split(separator: "\n").count, 300)
        await assertCommand(MSPFmtCommand(), ["-w", "12", "in.txt"], workspace: workspace, stdout: "alpha beta\ngamma delta\n")
        await assertCommand(MSPFmtCommand(), ["-w", "5", "a", "b"], workspace: workspace, stdout: "a\nb c\nd\ne f\n")
        await assertCommand(
            MSPFmtCommand(),
            ["-p", "# ", "-w", "12"],
            stdin: Data("# alpha beta gamma\n# delta epsilon\n".utf8),
            stdout: "# alpha\n# beta\n# gamma\n# delta\n# epsilon\n"
        )
        await assertCommand(MSPFmtCommand(), ["-c", "-w", "12"], stdin: Data("> alpha beta\n> gamma delta\n".utf8), stdout: "> alpha\nbeta >\ngamma delta\n")
        await assertCommand(
            MSPFmtCommand(),
            ["-w", "nope"],
            stderr: "fmt: invalid width: \u{2018}nope\u{2019}\n",
            exitCode: 1
        )
        await assertCommand(
            MSPFmtCommand(),
            ["-g", "90", "-w", "80"],
            stderr: "fmt: invalid width: \u{2018}90\u{2019}: Numerical result out of range\n",
            exitCode: 1
        )
        await assertCommand(
            MSPFmtCommand(),
            ["missing"],
            workspace: workspace,
            stderr: "fmt: cannot open 'missing' for reading: No such file or directory\n",
            exitCode: 1
        )
        await assertCommand(MSPFmtCommand(), ["-w", "8", "a b"], workspace: workspace, stdout: "alpha\nbeta\ngamma\n")
    }

    private func assertCommand(
        _ command: any MSPCommand,
        _ arguments: [String],
        workspace: (any MSPWorkspace)? = nil,
        stdin: Data = Data(),
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32 = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await assertCommand(
            command,
            arguments,
            workspace: workspace,
            stdin: stdin,
            stdoutData: Data(stdout.utf8),
            stderrData: Data(stderr.utf8),
            exitCode: exitCode,
            file: file,
            line: line
        )
    }

    private func assertCommand(
        _ command: any MSPCommand,
        _ arguments: [String],
        workspace: (any MSPWorkspace)? = nil,
        stdin: Data = Data(),
        stdoutData: Data,
        stderrData: Data = Data(),
        exitCode: Int32 = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let result = await runCommand(command, arguments, workspace: workspace, standardInput: stdin)
        XCTAssertEqual(result.stdoutData, stdoutData, "stdout mismatch for \(command.name) \(arguments)", file: file, line: line)
        XCTAssertEqual(result.stderrData, stderrData, "stderr mismatch for \(command.name) \(arguments)", file: file, line: line)
        XCTAssertEqual(result.exitCode, exitCode, "exit code mismatch for \(command.name) \(arguments)", file: file, line: line)
    }

    private func runCommand(
        _ command: any MSPCommand,
        _ arguments: [String],
        workspace: (any MSPWorkspace)? = nil,
        standardInput: Data = Data()
    ) async -> MSPCommandResult {
        do {
            return try await command.run(
                invocation: MSPCommandInvocation(name: command.name, arguments: arguments),
                context: MSPCommandContext(workspace: workspace, standardInput: standardInput)
            )
        } catch let failure as MSPCommandFailure {
            return failure.result
        } catch {
            return .failure(stderr: "\(command.name): \(error)\n")
        }
    }
}

private final class TextLayoutWorkspace: MSPWorkspace, @unchecked Sendable {
    let rootPath = "/"
    let textLayoutFileSystem: TextLayoutFileSystem
    var fileSystem: any MSPWorkspaceFileSystem { textLayoutFileSystem }

    init(files: [String: Data] = [:], directories: Set<String> = []) {
        self.textLayoutFileSystem = TextLayoutFileSystem(files: files, directories: directories)
    }
}

private final class TextLayoutFileSystem: MSPWorkspaceFileSystem, @unchecked Sendable {
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
        if let data = files[virtualPath] {
            return MSPFileInfo(virtualPath: virtualPath, type: .regularFile, size: Int64(data.count))
        }
        if directories.contains(virtualPath) {
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
        files[virtualPath] = data
    }

    func createDirectory(_ path: String, from currentDirectory: String, intermediates: Bool) throws {
        directories.insert(try resolve(path, from: currentDirectory).virtualPath)
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
