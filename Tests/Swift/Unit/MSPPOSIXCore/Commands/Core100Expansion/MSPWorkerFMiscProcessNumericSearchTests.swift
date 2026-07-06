import Foundation
import Dispatch
import XCTest
import MSPCore
import MSPPOSIXCore

final class MSPWorkerFMiscProcessNumericSearchTests: XCTestCase {
    func testDateBcAndNumfmtMatchStableGNUOracleCases() async throws {
        let workspace = WorkerFWorkspace(files: [
            "/expr.bc": Data("2+3\n".utf8)
        ])

        let dateOperand = await runCommand("date", ["foo"])
        let dateHelp = await runCommand("date", ["--help"])
        let dateVersion = await runCommand("date", ["--version"])
        let exprHelp = await runCommand("expr", ["--help"])
        let exprVersion = await runCommand("expr", ["--version"])
        let bcStdin = await runCommand(
            "bc",
            [],
            standardInput: Data("scale=2; 1/4\n5+7\n".utf8)
        )
        let bcBaseState = await runCommand(
            "bc",
            [],
            standardInput: Data("ibase=16\nobase=10\nFF\n".utf8)
        )
        let bcFile = await runCommand("bc", ["expr.bc"], workspace: workspace)
        let bcSyntax = await runCommand("bc", [], standardInput: Data("1+\n".utf8))
        let bcHelp = await runCommand("bc", ["-h"])
        let bcVersion = await runCommand("bc", ["-v"])
        let numfmtPadded = await runCommand(
            "numfmt",
            ["--to=si", "--suffix=B", "--padding=8"],
            standardInput: Data("1500\n".utf8)
        )
        let numfmtFromSI = await runCommand(
            "numfmt",
            ["--from=si"],
            standardInput: Data("1.5K\n".utf8)
        )
        let numfmtInvalidField = await runCommand(
            "numfmt",
            ["--field=2", "--to=si"],
            standardInput: Data("aa abc zz\nnext 1500 zz\n".utf8)
        )
        let numfmtHelp = await runCommand("numfmt", ["--help"])
        let numfmtVersion = await runCommand("numfmt", ["--version"])

        XCTAssertEqual(dateOperand.stdout, "")
        XCTAssertEqual(dateOperand.stderr, "date: invalid date \u{2018}foo\u{2019}\n")
        XCTAssertEqual(dateOperand.exitCode, 1)
        XCTAssertTrue(dateHelp.stdout.hasPrefix("Usage: date [OPTION]... [+FORMAT]\n"))
        XCTAssertEqual(dateVersion.stdout, "date (GNU coreutils) 9.1\n")
        XCTAssertTrue(exprHelp.stdout.hasPrefix("Usage: expr EXPRESSION\n"))
        XCTAssertEqual(exprVersion.stdout, "expr (GNU coreutils) 9.1\n")
        XCTAssertEqual(bcStdin.stdout, ".25\n12\n")
        XCTAssertEqual(bcStdin.stderr, "")
        XCTAssertEqual(bcStdin.exitCode, 0)
        XCTAssertEqual(bcBaseState.stdout, "FF\n")
        XCTAssertEqual(bcBaseState.stderr, "")
        XCTAssertEqual(bcBaseState.exitCode, 0)
        XCTAssertEqual(bcFile.stdout, "5\n")
        XCTAssertEqual(bcFile.stderr, "")
        XCTAssertEqual(bcFile.exitCode, 0)
        XCTAssertEqual(bcSyntax.stdout, "")
        XCTAssertEqual(bcSyntax.stderr, "(standard_in) 2: syntax error\n")
        XCTAssertEqual(bcSyntax.exitCode, 0)
        XCTAssertTrue(bcHelp.stdout.hasPrefix("usage: bc [options] [file ...]\n"))
        XCTAssertEqual(bcHelp.exitCode, 0)
        XCTAssertEqual(bcVersion.stdout, "bc 1.07.1\n")
        XCTAssertEqual(bcVersion.exitCode, 0)
        XCTAssertEqual(numfmtPadded.stdout, "   1.5KB\n")
        XCTAssertEqual(numfmtPadded.stderr, "")
        XCTAssertEqual(numfmtPadded.exitCode, 0)
        XCTAssertEqual(numfmtFromSI.stdout, "1500\n")
        XCTAssertEqual(numfmtFromSI.stderr, "")
        XCTAssertEqual(numfmtFromSI.exitCode, 0)
        XCTAssertEqual(numfmtInvalidField.stdout, "aa ")
        XCTAssertEqual(numfmtInvalidField.stderr, "numfmt: invalid number: \u{2018}abc\u{2019}\n")
        XCTAssertEqual(numfmtInvalidField.exitCode, 2)
        XCTAssertTrue(numfmtHelp.stdout.hasPrefix("Usage: numfmt [OPTION]... [NUMBER]...\n"))
        XCTAssertEqual(numfmtVersion.stdout, "numfmt (GNU coreutils) 9.1\n")
    }

    func testNumfmtStreamsStandardInputRecords() async throws {
        let input = WorkerFChunkedInputStream(["1500\n", "2048\n", "bad"])
        let output = WorkerFCollectingOutputStream()

        let result = try await MSPNumfmtCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "numfmt", arguments: ["--to=si", "--suffix=B"]),
            context: MSPCommandContext(
                standardInputStream: input,
                standardOutputStream: output
            )
        )

        let outputText = await output.string()
        let inputReadCount = await input.readCount()
        XCTAssertEqual(outputText, "1.5KB\n2.0KB\n")
        XCTAssertEqual(result.stderr, "numfmt: invalid number: \u{2018}bad\u{2019}\n")
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertEqual(inputReadCount, 3)
    }

    func testBcStreamsStandardInputLinesWithPersistentScaleState() async throws {
        let input = WorkerFChunkedInputStream(["scale=2; 1/4\n", "5+7\n", "1+\n"])
        let output = WorkerFCollectingOutputStream()

        let result = try await MSPBcCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "bc"),
            context: MSPCommandContext(
                standardInputStream: input,
                standardOutputStream: output
            )
        )

        let outputText = await output.string()
        let inputReadCount = await input.readCount()
        XCTAssertEqual(outputText, ".25\n12\n")
        XCTAssertEqual(result.stderr, "(standard_in) 4: syntax error\n")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(inputReadCount, 3)
    }

    func testPsTimeoutAndLddMatchStableGNUOracleCases() async throws {
        let workspace = WorkerFWorkspace(files: [
            "/plain.txt": Data("hello\n".utf8),
            "/dir/nested.txt": Data("x\n".utf8)
        ])

        let psInvalid = await runCommand("ps", ["--bad-option"])
        let psCustom = await runCommand("ps", ["-o", "pid,comm"])
        let psHeaderlessComm = await runCommand("ps", ["-o", "comm=", "-p", "12345"])
        let psNoMatchingPID = await runCommand("ps", ["--format=pid,comm", "--no-headers", "--pid", "999"])
        let psMatchingPPID = await runCommand("ps", ["--format=pid,ppid,comm", "--ppid=0"])
        let psNoMatchingPPID = await runCommand("ps", ["--format=pid,comm", "--ppid", "999"])
        let psFullListing = await runCommand("ps", ["-f"])
        let psHelpOutput = await runCommand("ps", ["--help", "output"])
        let psVersion = await runCommand("ps", ["--version"])
        let timeoutBasic = await runCommand("timeout", ["1", "printf", "done\n"])
        let timeoutFalse = await runCommand("timeout", ["1", "false"])
        let timeoutMissing = await runCommand("timeout", ["1", "no-such-cmd"])
        let timeoutInvalidInterval = await runCommand("timeout", ["nope", "true"])
        let timeoutInvalidOption = await runCommand("timeout", ["--bad", "1", "true"])
        let timeoutHelp = await runCommand("timeout", ["--help"])
        let timeoutVersion = await runCommand("timeout", ["--version"])
        let timeoutVerbose = await runCommand("timeout", ["-v", "0.02", "sleep", "inf"])
        let lddPlain = await runCommand("ldd", ["plain.txt"], workspace: workspace)
        let lddHelp = await runCommand("ldd", ["--help"], workspace: workspace)
        let lddVersion = await runCommand("ldd", ["--version"], workspace: workspace)
        let lddVersionAbbrev = await runCommand("ldd", ["--vers"], workspace: workspace)
        let lddAmbiguous = await runCommand("ldd", ["--ver"], workspace: workspace)
        let lddAcceptedOptions = await runCommand("ldd", ["-d", "-r", "-u", "-v", "plain.txt"], workspace: workspace)
        let lddMissing = await runCommand("ldd", ["missing"], workspace: workspace)
        let lddDirectory = await runCommand("ldd", ["dir"], workspace: workspace)

        XCTAssertEqual(psInvalid.stdout, "")
        XCTAssertEqual(
            psInvalid.stderr,
            """
            error: unknown gnu long option

            Usage:
             ps [options]

             Try 'ps --help <simple|list|output|threads|misc|all>'
              or 'ps --help <s|l|o|t|m|a>'
             for additional help text.

            For more details see ps(1).

            """
        )
        XCTAssertEqual(psInvalid.exitCode, 1)
        XCTAssertEqual(psCustom.stdout, "    PID COMMAND\n  12345 bash\n")
        XCTAssertEqual(psHeaderlessComm.stdout, "ps\n")
        XCTAssertEqual(psNoMatchingPID.stdout, "")
        XCTAssertEqual(psMatchingPPID.stdout, "    PID    PPID COMMAND\n  12345       0 bash\n")
        XCTAssertEqual(psNoMatchingPPID.stdout, "    PID COMMAND\n")
        XCTAssertEqual(psFullListing.stdout, """
        UID          PID    PPID  C STIME TTY          TIME CMD
        msp            1       0  0 00:00 ?        00:00:00 msp-shell

        """)
        XCTAssertTrue(psHelpOutput.stdout.contains("Help category: output\n"))
        XCTAssertEqual(psVersion.stdout, "ps from procps-ng 4.0.2\n")
        XCTAssertEqual(timeoutBasic.stdout, "done\n")
        XCTAssertEqual(timeoutBasic.stderr, "")
        XCTAssertEqual(timeoutBasic.exitCode, 0)
        XCTAssertEqual(timeoutFalse.stdout, "")
        XCTAssertEqual(timeoutFalse.stderr, "")
        XCTAssertEqual(timeoutFalse.exitCode, 1)
        XCTAssertEqual(
            timeoutMissing.stderr,
            "timeout: failed to run command \u{2018}no-such-cmd\u{2019}: No such file or directory\n"
        )
        XCTAssertEqual(timeoutMissing.exitCode, 127)
        XCTAssertEqual(
            timeoutInvalidInterval.stderr,
            "timeout: invalid time interval \u{2018}nope\u{2019}\nTry 'timeout --help' for more information.\n"
        )
        XCTAssertEqual(timeoutInvalidInterval.exitCode, 125)
        XCTAssertEqual(
            timeoutInvalidOption.stderr,
            "timeout: unrecognized option '--bad'\nTry 'timeout --help' for more information.\n"
        )
        XCTAssertEqual(timeoutInvalidOption.exitCode, 125)
        XCTAssertTrue(timeoutHelp.stdout.hasPrefix("Usage: timeout [OPTION] DURATION COMMAND [ARG]...\n"))
        XCTAssertEqual(timeoutVersion.stdout, "timeout (GNU coreutils) 9.1\n")
        XCTAssertEqual(
            timeoutVerbose.stderr,
            "timeout: sending signal TERM to command \u{2018}sleep\u{2019}\n"
        )
        XCTAssertEqual(timeoutVerbose.exitCode, 124)
        XCTAssertEqual(lddPlain.stdout, "")
        XCTAssertEqual(lddPlain.stderr, "\tnot a dynamic executable\n")
        XCTAssertEqual(lddPlain.exitCode, 1)
        XCTAssertTrue(lddHelp.stdout.hasPrefix("Usage: ldd [OPTION]... FILE...\n"))
        XCTAssertTrue(lddVersion.stdout.hasPrefix("ldd (Debian GLIBC 2.36-9+deb12u14) 2.36\n"))
        XCTAssertEqual(lddVersionAbbrev.stdout, lddVersion.stdout)
        XCTAssertEqual(lddAmbiguous.stderr, "ldd: option '--ver' is ambiguous\n")
        XCTAssertEqual(lddAmbiguous.exitCode, 1)
        XCTAssertEqual(lddAcceptedOptions.stderr, "\tnot a dynamic executable\n")
        XCTAssertEqual(lddAcceptedOptions.exitCode, 1)
        XCTAssertEqual(lddVersion.exitCode, 0)
        XCTAssertEqual(lddMissing.stderr, "ldd: ./missing: No such file or directory\n")
        XCTAssertEqual(lddMissing.exitCode, 1)
        XCTAssertEqual(lddDirectory.stderr, "ldd: ./dir: not regular file\n")
        XCTAssertEqual(lddDirectory.exitCode, 1)
    }

    func testTimeoutReturnsPromptlyWhenSubcommandDoesNotCooperateWithCancellation() async throws {
        let startedAt = Date()

        let result = try await MSPTimeoutCommand().run(
            invocation: MSPCommandInvocation(name: "timeout", arguments: ["0.02", "slow"]),
            context: MSPCommandContext(
                availableCommandNames: ["slow"],
                subcommandRunner: { _, _ in
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        DispatchQueue.global().asyncAfter(deadline: .now() + 0.35) {
                            continuation.resume()
                        }
                    }
                    return .success(stdout: "late\n")
                }
            )
        )

        let elapsed = Date().timeIntervalSince(startedAt)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 124)
        XCTAssertLessThan(elapsed, 0.2)
    }

    func testSleepMatchesGNUCoreutilsIntervalParsingAndDiagnostics() async throws {
        let zero = await runCommand("sleep", ["0"])
        let fraction = await runCommand("sleep", ["0.001"])
        let suffix = await runCommand("sleep", ["0.001s"])
        let multiple = await runCommand("sleep", ["0", "0.001"])
        let hexFloat = await runCommand("sleep", ["0x.002p1"])
        let hexFloatWithSuffix = await runCommand("sleep", ["0x.002p1s"])
        let doubleDashOnly = await runCommand("sleep", ["--"])
        let invalid = await runCommand("sleep", ["nope"])
        let missing = await runCommand("sleep", [])
        let negativeOption = await runCommand("sleep", ["-1"])
        let negativeAfterSeparator = await runCommand("sleep", ["--", "-1"])
        let optionAfterOperand = await runCommand("sleep", ["0", "-x"])
        let invalidSuffix = await runCommand("sleep", ["42d", "42day"])
        let nan = await runCommand("sleep", ["nan"])
        let help = await runCommand("sleep", ["--help"])
        let version = await runCommand("sleep", ["--version"])

        for result in [zero, fraction, suffix, multiple, hexFloat, hexFloatWithSuffix, doubleDashOnly] {
            XCTAssertEqual(result.stdout, "")
            XCTAssertEqual(result.stderr, "")
            XCTAssertEqual(result.exitCode, 0)
        }
        XCTAssertEqual(invalid.stdout, "")
        XCTAssertEqual(
            invalid.stderr,
            "sleep: invalid time interval \u{2018}nope\u{2019}\nTry 'sleep --help' for more information.\n"
        )
        XCTAssertEqual(invalid.exitCode, 1)
        XCTAssertEqual(missing.stdout, "")
        XCTAssertEqual(
            missing.stderr,
            "sleep: missing operand\nTry 'sleep --help' for more information.\n"
        )
        XCTAssertEqual(missing.exitCode, 1)
        XCTAssertEqual(
            negativeOption.stderr,
            "sleep: invalid option -- '1'\nTry 'sleep --help' for more information.\n"
        )
        XCTAssertEqual(negativeOption.exitCode, 1)
        XCTAssertEqual(
            negativeAfterSeparator.stderr,
            "sleep: invalid time interval \u{2018}-1\u{2019}\nTry 'sleep --help' for more information.\n"
        )
        XCTAssertEqual(negativeAfterSeparator.exitCode, 1)
        XCTAssertEqual(
            optionAfterOperand.stderr,
            "sleep: invalid option -- 'x'\nTry 'sleep --help' for more information.\n"
        )
        XCTAssertEqual(optionAfterOperand.exitCode, 1)
        XCTAssertEqual(
            invalidSuffix.stderr,
            "sleep: invalid time interval \u{2018}42day\u{2019}\nTry 'sleep --help' for more information.\n"
        )
        XCTAssertEqual(invalidSuffix.exitCode, 1)
        XCTAssertEqual(
            nan.stderr,
            "sleep: invalid time interval \u{2018}nan\u{2019}\nTry 'sleep --help' for more information.\n"
        )
        XCTAssertEqual(nan.exitCode, 1)
        XCTAssertTrue(help.stdout.hasPrefix("Usage: sleep NUMBER[SUFFIX]...\n"))
        XCTAssertEqual(version.stdout, "sleep (GNU coreutils) 9.1\n")
    }

    func testTimeoutCancelsSleepPromptly() async throws {
        let startedAt = Date()

        let result = await runCommand("timeout", ["0.02", "sleep", "1"])

        let elapsed = Date().timeIntervalSince(startedAt)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 124)
        XCTAssertLessThan(elapsed, 0.2)
    }

    func testRgUsesRipgrepLikePathDisplayDiagnosticsAndGlobs() async throws {
        let workspace = WorkerFWorkspace(files: [
            "/.hidden": Data("secret\n".utf8),
            "/a.txt": Data("alpha\nbeta\n".utf8),
            "/sub/b.md": Data("alpha\n".utf8),
            "/sub/c.txt": Data("alpha\n".utf8),
            "/words.txt": Data("alpha alphabet\nexact\n".utf8)
        ])

        let defaultSearch = await runCommand("rg", ["-n", "alpha"], workspace: workspace)
        let explicitDotSearch = await runCommand("rg", ["-n", "alpha", "."], workspace: workspace)
        let filesDefault = await runCommand("rg", ["--files"], workspace: workspace)
        let filesExplicitDot = await runCommand("rg", ["--files", "."], workspace: workspace)
        let globSearch = await runCommand("rg", ["-n", "-g", "*.txt", "alpha"], workspace: workspace)
        let globFiles = await runCommand("rg", ["--files", "--glob=*.txt"], workspace: workspace)
        let globExclude = await runCommand("rg", ["--files", "-g!sub/*"], workspace: workspace)
        let missingPath = await runCommand("rg", ["alpha", "missing"], workspace: workspace)
        let filesWithMatches = await runCommand("rg", ["-l", "alpha"], workspace: workspace)
        let hidden = await runCommand("rg", ["--hidden", "-n", "secret"], workspace: workspace)
        let fixedMultiple = await runCommand("rg", ["-F", "-e", "alpha", "-e", "beta", "-I", "a.txt"], workspace: workspace)
        let inverted = await runCommand("rg", ["-v", "beta", "-I", "a.txt"], workspace: workspace)
        let count = await runCommand("rg", ["-c", "alpha", "-I", "a.txt"], workspace: workspace)
        let word = await runCommand("rg", ["-w", "alpha", "-I", "words.txt"], workspace: workspace)
        let line = await runCommand("rg", ["-x", "exact", "-I", "words.txt"], workspace: workspace)
        let quiet = await runCommand("rg", ["-q", "alpha"], workspace: workspace)
        let noMessages = await runCommand("rg", ["--no-messages", "alpha", "missing"], workspace: workspace)
        let help = await runCommand("rg", ["-h"], workspace: workspace)

        XCTAssertEqual(defaultSearch.stdout, "a.txt:1:alpha\nsub/b.md:1:alpha\nsub/c.txt:1:alpha\nwords.txt:1:alpha alphabet\n")
        XCTAssertEqual(defaultSearch.stderr, "")
        XCTAssertEqual(defaultSearch.exitCode, 0)
        XCTAssertEqual(explicitDotSearch.stdout, "./a.txt:1:alpha\n./sub/b.md:1:alpha\n./sub/c.txt:1:alpha\n./words.txt:1:alpha alphabet\n")
        XCTAssertEqual(filesDefault.stdout, "a.txt\nsub/b.md\nsub/c.txt\nwords.txt\n")
        XCTAssertEqual(filesExplicitDot.stdout, "./a.txt\n./sub/b.md\n./sub/c.txt\n./words.txt\n")
        XCTAssertEqual(globSearch.stdout, "a.txt:1:alpha\nsub/c.txt:1:alpha\nwords.txt:1:alpha alphabet\n")
        XCTAssertEqual(globFiles.stdout, "a.txt\nsub/c.txt\nwords.txt\n")
        XCTAssertEqual(globExclude.stdout, "a.txt\nwords.txt\n")
        XCTAssertEqual(missingPath.stdout, "")
        XCTAssertEqual(missingPath.stderr, "missing: No such file or directory (os error 2)\n")
        XCTAssertEqual(missingPath.exitCode, 2)
        XCTAssertEqual(filesWithMatches.stdout, "a.txt\nsub/b.md\nsub/c.txt\nwords.txt\n")
        XCTAssertEqual(hidden.stdout, ".hidden:1:secret\n")
        XCTAssertEqual(fixedMultiple.stdout, "alpha\nbeta\n")
        XCTAssertEqual(inverted.stdout, "alpha\n")
        XCTAssertEqual(count.stdout, "1\n")
        XCTAssertEqual(word.stdout, "alpha alphabet\n")
        XCTAssertEqual(line.stdout, "exact\n")
        XCTAssertEqual(quiet.stdout, "")
        XCTAssertEqual(quiet.stderr, "")
        XCTAssertEqual(quiet.exitCode, 0)
        XCTAssertEqual(noMessages.stdout, "")
        XCTAssertEqual(noMessages.stderr, "")
        XCTAssertEqual(noMessages.exitCode, 2)
        XCTAssertTrue(help.stdout.hasPrefix("ripgrep 13.0.0\nUsage: rg"))
        XCTAssertEqual(help.exitCode, 0)
    }

    func testRgStreamingWritesOutputAndDiagnosticsThroughStreams() async throws {
        let workspace = WorkerFWorkspace(files: [
            "/a.txt": Data("alpha\n".utf8),
            "/b.txt": Data("beta\n".utf8)
        ])
        let standardOutput = WorkerFCollectingOutputStream()
        let standardError = WorkerFCollectingOutputStream()

        let result = try await MSPRgCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "rg", arguments: ["-n", "alpha", "a.txt", "b.txt", "missing"]),
            context: MSPCommandContext(
                workspace: workspace,
                standardOutputStream: standardOutput,
                standardErrorStream: standardError
            )
        )

        let stdout = await standardOutput.string()
        let stderr = await standardError.string()
        XCTAssertEqual(stdout, "a.txt:1:alpha\n")
        XCTAssertEqual(stderr, "missing: No such file or directory (os error 2)\n")
        XCTAssertEqual(result.stdoutData, Data())
        XCTAssertEqual(result.stderr, "missing: No such file or directory (os error 2)\n")
        XCTAssertEqual(result.exitCode, 2)
    }

    func testRgStreamingTreatsBrokenOutputPipeAsSuccess() async throws {
        let workspace = WorkerFWorkspace(files: [
            "/a.txt": Data("alpha\n".utf8)
        ])

        let result = try await MSPRgCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "rg", arguments: ["alpha"]),
            context: MSPCommandContext(
                workspace: workspace,
                standardOutputStream: WorkerFBrokenPipeOutputStream()
            )
        )

        XCTAssertEqual(result.stdoutData, Data())
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
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
            context: MSPCommandContext(
                workspace: workspace,
                standardInput: standardInput,
                availableCommandNames: registry.commandNames,
                subcommandRunner: { invocation, context in
                    await executor.run(invocation: invocation, context: context)
                }
            )
        )
    }
}

private final class WorkerFChunkedInputStream: MSPCommandInputStream, @unchecked Sendable {
    private let storage: WorkerFChunkedInputStorage

    init(_ chunks: [String]) {
        storage = WorkerFChunkedInputStorage(chunks.map { Data($0.utf8) })
    }

    func read(maxBytes: Int) async throws -> Data? {
        await storage.read()
    }

    func closeRead() async {
        await storage.close()
    }

    func readCount() async -> Int {
        await storage.readCount()
    }
}

private actor WorkerFChunkedInputStorage {
    private var chunks: [Data]
    private var closed = false
    private var reads = 0

    init(_ chunks: [Data]) {
        self.chunks = chunks
    }

    func read() -> Data? {
        guard !closed, !chunks.isEmpty else {
            return nil
        }
        reads += 1
        return chunks.removeFirst()
    }

    func close() {
        closed = true
        chunks.removeAll()
    }

    func readCount() -> Int {
        reads
    }
}

private final class WorkerFCollectingOutputStream: MSPCommandOutputStream, @unchecked Sendable {
    private let storage = WorkerFCollectingOutputStorage()

    func write(_ data: Data) async throws {
        await storage.write(data)
    }

    func closeWrite() async {}

    func string() async -> String {
        await storage.string()
    }
}

private actor WorkerFCollectingOutputStorage {
    private var data = Data()

    func write(_ chunk: Data) {
        data.append(chunk)
    }

    func string() -> String {
        String(decoding: data, as: UTF8.self)
    }
}

private struct WorkerFBrokenPipeOutputStream: MSPCommandOutputStream {
    func write(_ data: Data) async throws {
        throw MSPCommandStreamError.brokenPipe
    }

    func closeWrite() async {}
}

private struct WorkerFWorkspace: MSPWorkspace {
    let rootPath = "/"
    let fileSystem: any MSPWorkspaceFileSystem

    init(files: [String: Data]) {
        self.fileSystem = WorkerFWorkspaceFileSystem(files: files)
    }
}

private struct WorkerFWorkspaceFileSystem: MSPWorkspaceFileSystem {
    let policy = MSPWorkspaceFileSystemPolicy.default
    var files: [String: Data]

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
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard isDirectory(virtualPath) else {
            throw MSPWorkspaceFileSystemError.notDirectory(virtualPath)
        }
        let prefix = virtualPath == "/" ? "/" : virtualPath + "/"
        let childNames = Set(files.keys.compactMap { filePath -> String? in
            guard filePath.hasPrefix(prefix) else {
                return nil
            }
            let remainder = String(filePath.dropFirst(prefix.count))
            return remainder.split(separator: "/", maxSplits: 1).first.map(String.init)
        })
        return try childNames.sorted().map { name in
            let childPath = prefix + name
            return MSPDirectoryEntry(name: name, info: try stat(childPath, from: "/"))
        }
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

    private func isDirectory(_ virtualPath: String) -> Bool {
        if virtualPath == "/" {
            return true
        }
        return files.keys.contains { $0.hasPrefix(virtualPath + "/") }
    }
}
