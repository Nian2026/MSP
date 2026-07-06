import Foundation
import XCTest
import MSPCore
import MSPPOSIXCore

final class MSPXargsCommandTests: XCTestCase {
    func testXargsSplitsBatchesAtMaxChars() async throws {
        let capture = XargsCommandLineCapture()
        let runner: MSPCommandLineRunner = { commandLine, _ in
            await capture.append(commandLine)
            return .success(stdout: commandLine + "\n")
        }

        let result = try await MSPXargsCommand().run(
            invocation: MSPCommandInvocation(name: "xargs", arguments: ["-s", "10", "echo"]),
            context: MSPCommandContext(
                standardInput: Data("aa bb cc dd\n".utf8),
                commandLineRunner: runner
            )
        )

        let capturedLines = await capture.lines()
        XCTAssertEqual(capturedLines, ["echo aa bb", "echo cc dd"])
        XCTAssertEqual(result.stdout, "echo aa bb\necho cc dd\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testXargsPreservesSubcommandModelContentItemsWithoutChangingTextShape() async throws {
        let runner: MSPCommandLineRunner = { commandLine, _ in
            .success(
                stdout: "ran \(commandLine)\n",
                modelContentItems: [
                    .inputImage(
                        data: Data(commandLine.utf8),
                        mimeType: "image/png",
                        detail: "high"
                    )
                ]
            )
        }

        let result = try await MSPXargsCommand().run(
            invocation: MSPCommandInvocation(name: "xargs", arguments: ["-n1", "media", "view"]),
            context: MSPCommandContext(
                standardInput: Data("/图库/a.png\n/图库/b.png\n".utf8),
                commandLineRunner: runner
            )
        )

        XCTAssertEqual(result.stdout, "ran media view '/图库/a.png'\nran media view '/图库/b.png'\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.modelContentItems, [
            .inputImage(data: Data("media view '/图库/a.png'".utf8), mimeType: "image/png", detail: "high"),
            .inputImage(data: Data("media view '/图库/b.png'".utf8), mimeType: "image/png", detail: "high")
        ])
    }

    func testStreamingXargsExecutesFirstBatchBeforeInputEOF() async throws {
        let input = XargsGatedChunkedInputStream(first: "a\0b\0", second: "c\0")
        let output = XargsCollectingOutputStream()
        let error = XargsCollectingOutputStream()
        let capture = XargsCommandLineCapture()
        let runner: MSPCommandLineRunner = { commandLine, _ in
            await capture.append(commandLine)
            return .success(stdout: commandLine + "\n")
        }

        let task = Task {
            try await MSPXargsCommand().runStreaming(
                invocation: MSPCommandInvocation(name: "xargs", arguments: ["-0", "-n", "2", "echo"]),
                context: MSPCommandContext(
                    standardInputStream: input,
                    standardOutputStream: output,
                    standardErrorStream: error,
                    commandLineRunner: runner
                )
            )
        }

        await input.waitForSecondReadAttempt()
        let firstCapturedLines = await capture.lines()
        await input.releaseSecondChunk()
        XCTAssertEqual(firstCapturedLines, ["echo a b"])

        let result = try await task.value
        let outputText = await output.string()
        let errorText = await error.string()
        let finalCapturedLines = await capture.lines()
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(outputText, "echo a b\necho c\n")
        XCTAssertEqual(errorText, "")
        XCTAssertEqual(finalCapturedLines, ["echo a b", "echo c"])
    }

    func testStreamingXargsPassesOutputStreamsToSubcommands() async throws {
        let input = XargsChunkedInputStream(["a\0b\0"])
        let output = XargsCollectingOutputStream()
        let error = XargsCollectingOutputStream()
        let runner: MSPSubcommandRunner = { invocation, context in
            guard let stream = context.standardOutputStream else {
                return .failure(exitCode: 1, stderr: "missing child stream\n")
            }
            try? await stream.write(Data("child \(invocation.arguments.joined(separator: ","))\n".utf8))
            return .success()
        }

        let result = try await MSPXargsCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "xargs", arguments: ["-0", "-n", "2", "echo"]),
            context: MSPCommandContext(
                standardInputStream: input,
                standardOutputStream: output,
                standardErrorStream: error,
                subcommandRunner: runner
            )
        )

        let outputText = await output.string()
        let errorText = await error.string()
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(outputText, "child a,b\n")
        XCTAssertEqual(errorText, "")
    }

    func testXargsSupportsArgFileLogicalLinesReplacementAndEOF() async throws {
        let capture = XargsCommandLineCapture()
        let runner: MSPCommandLineRunner = { commandLine, _ in
            await capture.append(commandLine)
            return .success(stdout: commandLine + "\n")
        }
        let workspace = XargsWorkspace(fileSystem: XargsStreamingFileSystem(files: [
            "/args.txt": Data("aa bb\ncc\nSTOP\ndd\n".utf8)
        ]))

        let lines = try await MSPXargsCommand().run(
            invocation: MSPCommandInvocation(
                name: "xargs",
                arguments: ["-a", "args.txt", "-E", "STOP", "-L", "2", "echo", "initial"]
            ),
            context: MSPCommandContext(
                workspace: workspace,
                commandLineRunner: runner
            )
        )
        let replacement = try await MSPXargsCommand().run(
            invocation: MSPCommandInvocation(name: "xargs", arguments: ["-i", "echo", "{}"]),
            context: MSPCommandContext(
                standardInput: Data("one two\nthree\n".utf8),
                commandLineRunner: runner
            )
        )

        let capturedLines = await capture.lines()
        XCTAssertEqual(capturedLines, [
            "echo initial aa bb cc",
            "echo 'one two'",
            "echo three"
        ])
        XCTAssertEqual(lines.stdout, "echo initial aa bb cc\n")
        XCTAssertEqual(lines.stderr, "")
        XCTAssertEqual(lines.exitCode, 0)
        XCTAssertEqual(replacement.stdout, "echo 'one two'\necho three\n")
        XCTAssertEqual(replacement.stderr, "")
        XCTAssertEqual(replacement.exitCode, 0)
    }

    func testStreamingXargsInputOnlyFallbackConsumesInputStream() async throws {
        let registry = try MSPCommandRegistry(commands: [MSPXargsCommand()])
        let executor = MSPCommandExecutor(registry: registry)
        let input = XargsChunkedInputStream(["a b\n"])
        let capture = XargsCommandLineCapture()
        let runner: MSPCommandLineRunner = { commandLine, _ in
            await capture.append(commandLine)
            return .success(stdout: commandLine + "\n")
        }

        let result = await executor.run(
            invocation: MSPCommandInvocation(name: "xargs", arguments: ["-n", "1", "echo"]),
            context: MSPCommandContext(
                standardInputStream: input,
                commandLineRunner: runner
            )
        )

        let capturedLines = await capture.lines()
        let inputReadCount = await input.readCount()
        XCTAssertEqual(capturedLines, ["echo a", "echo b"])
        XCTAssertEqual(inputReadCount, 1)
        XCTAssertEqual(result.stdout, "echo a\necho b\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testStreamingXargsInputOnlyFallbackStopsUpstreamAfterChildExit255() async throws {
        let registry = try MSPCommandRegistry(commands: [MSPXargsCommand()])
        let executor = MSPCommandExecutor(registry: registry)
        let input = XargsChunkedInputStream(["a\0", "b\0"])
        let capture = XargsCommandLineCapture()
        let runner: MSPCommandLineRunner = { commandLine, _ in
            await capture.append(commandLine)
            return .failure(exitCode: 255, stdout: "first\n", stderr: "")
        }

        let result = await executor.run(
            invocation: MSPCommandInvocation(name: "xargs", arguments: ["-0", "-n", "1", "echo"]),
            context: MSPCommandContext(
                standardInputStream: input,
                commandLineRunner: runner
            )
        )

        let capturedLines = await capture.lines()
        let inputReadCount = await input.readCount()
        let inputIsReadClosed = await input.isReadClosed()
        XCTAssertEqual(capturedLines, ["echo a"])
        XCTAssertEqual(inputReadCount, 1)
        XCTAssertTrue(inputIsReadClosed)
        XCTAssertEqual(result.stdout, "first\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 124)
    }

    func testXargsStopsAfterChildExit255() async throws {
        let capture = XargsCommandLineCapture()
        let runner: MSPCommandLineRunner = { commandLine, _ in
            await capture.append(commandLine)
            return .failure(exitCode: 255, stdout: "first\n", stderr: "")
        }

        let result = try await MSPXargsCommand().run(
            invocation: MSPCommandInvocation(name: "xargs", arguments: ["-n", "1", "echo"]),
            context: MSPCommandContext(
                standardInput: Data("a b c\n".utf8),
                commandLineRunner: runner
            )
        )

        let capturedLines = await capture.lines()
        XCTAssertEqual(capturedLines, ["echo a"])
        XCTAssertEqual(result.stdout, "first\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 124)
    }

    func testStreamingXargsStopsReadingAfterChildExit255() async throws {
        let input = XargsChunkedInputStream(["a\0", "b\0"])
        let output = XargsCollectingOutputStream()
        let error = XargsCollectingOutputStream()
        let capture = XargsCommandLineCapture()
        let runner: MSPCommandLineRunner = { commandLine, _ in
            await capture.append(commandLine)
            return .failure(exitCode: 255, stdout: "first\n", stderr: "")
        }

        let result = try await MSPXargsCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "xargs", arguments: ["-0", "-n", "1", "echo"]),
            context: MSPCommandContext(
                standardInputStream: input,
                standardOutputStream: output,
                standardErrorStream: error,
                commandLineRunner: runner
            )
        )

        let capturedLines = await capture.lines()
        let inputReadCount = await input.readCount()
        let inputIsReadClosed = await input.isReadClosed()
        let outputText = await output.string()
        let errorText = await error.string()
        XCTAssertEqual(capturedLines, ["echo a"])
        XCTAssertEqual(inputReadCount, 1)
        XCTAssertTrue(inputIsReadClosed)
        XCTAssertEqual(outputText, "first\n")
        XCTAssertEqual(errorText, "")
        XCTAssertEqual(result.exitCode, 124)
    }

    func testArgFilePreservesChildStandardInput() async throws {
        let capture = XargsChildContextCapture()
        let runner: MSPCommandLineRunner = { commandLine, context in
            await capture.append(commandLine: commandLine, standardInput: context.standardInput)
            return .success(stdout: String(decoding: context.standardInput, as: UTF8.self))
        }
        let workspace = XargsWorkspace(fileSystem: XargsStreamingFileSystem(files: [
            "/args.txt": Data()
        ]))

        let result = try await MSPXargsCommand().run(
            invocation: MSPCommandInvocation(name: "xargs", arguments: ["-a", "args.txt", "cat"]),
            context: MSPCommandContext(
                workspace: workspace,
                standardInput: Data("payload\n".utf8),
                commandLineRunner: runner
            )
        )

        let capturedCommandLines = await capture.commandLines()
        let capturedStandardInputs = await capture.standardInputs()
        XCTAssertEqual(capturedCommandLines, ["cat"])
        XCTAssertEqual(capturedStandardInputs, ["payload\n"])
        XCTAssertEqual(result.stdout, "payload\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testBareLowercaseLDefaultsToOneLogicalLine() async throws {
        let capture = XargsCommandLineCapture()
        let runner: MSPCommandLineRunner = { commandLine, _ in
            await capture.append(commandLine)
            return .success(stdout: commandLine + "\n")
        }

        let result = try await MSPXargsCommand().run(
            invocation: MSPCommandInvocation(name: "xargs", arguments: ["-l", "echo"]),
            context: MSPCommandContext(
                standardInput: Data("a b\nc d\n".utf8),
                commandLineRunner: runner
            )
        )

        let capturedLines = await capture.lines()
        XCTAssertEqual(capturedLines, ["echo a b", "echo c d"])
        XCTAssertEqual(result.stdout, "echo a b\necho c d\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }
}

actor XargsCommandLineCapture {
    private var captured: [String] = []

    func append(_ commandLine: String) {
        captured.append(commandLine)
    }

    func lines() -> [String] {
        captured
    }
}

private actor XargsChildContextCapture {
    private var capturedCommandLines: [String] = []
    private var capturedStandardInputs: [String] = []

    func append(commandLine: String, standardInput: Data) {
        capturedCommandLines.append(commandLine)
        capturedStandardInputs.append(String(decoding: standardInput, as: UTF8.self))
    }

    func commandLines() -> [String] {
        capturedCommandLines
    }

    func standardInputs() -> [String] {
        capturedStandardInputs
    }
}

final class XargsChunkedInputStream: MSPCommandInputStream, @unchecked Sendable {
    private let storage: XargsChunkedInputStreamStorage

    init(_ chunks: [String]) {
        storage = XargsChunkedInputStreamStorage(chunks.map { Data($0.utf8) })
    }

    func read(maxBytes: Int) async throws -> Data? {
        await storage.read(maxBytes: maxBytes)
    }

    func closeRead() async {
        await storage.closeRead()
    }

    func readCount() async -> Int {
        await storage.readCount()
    }

    func isReadClosed() async -> Bool {
        await storage.isReadClosed()
    }
}

private actor XargsChunkedInputStreamStorage {
    private var chunks: [Data]
    private var closed = false
    private var reads = 0

    init(_ chunks: [Data]) {
        self.chunks = chunks
    }

    func read(maxBytes: Int) -> Data? {
        guard !closed, !chunks.isEmpty else {
            return nil
        }
        reads += 1
        return chunks.removeFirst()
    }

    func closeRead() {
        closed = true
        chunks.removeAll()
    }

    func readCount() -> Int {
        reads
    }

    func isReadClosed() -> Bool {
        closed
    }
}

private final class XargsGatedChunkedInputStream: MSPCommandInputStream, @unchecked Sendable {
    private let storage: XargsGatedChunkedInputStreamStorage

    init(first: String, second: String) {
        storage = XargsGatedChunkedInputStreamStorage(
            first: Data(first.utf8),
            second: Data(second.utf8)
        )
    }

    func read(maxBytes: Int) async throws -> Data? {
        await storage.read()
    }

    func closeRead() async {
        await storage.close()
    }

    func waitForSecondReadAttempt() async {
        await storage.waitForSecondReadAttempt()
    }

    func releaseSecondChunk() async {
        await storage.releaseSecondChunk()
    }
}

private actor XargsGatedChunkedInputStreamStorage {
    private var chunks: [Data]
    private var closed = false
    private var secondReadAttempted = false
    private var secondChunkReleased = false
    private var secondReadWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(first: Data, second: Data) {
        self.chunks = [first, second]
    }

    func read() async -> Data? {
        guard !closed, !chunks.isEmpty else {
            return nil
        }
        if chunks.count == 1 {
            secondReadAttempted = true
            for waiter in secondReadWaiters {
                waiter.resume()
            }
            secondReadWaiters.removeAll()
            if !secondChunkReleased {
                await withCheckedContinuation { continuation in
                    releaseWaiters.append(continuation)
                }
            }
        }
        guard !closed, !chunks.isEmpty else {
            return nil
        }
        return chunks.removeFirst()
    }

    func close() {
        closed = true
        chunks.removeAll()
        for waiter in secondReadWaiters {
            waiter.resume()
        }
        secondReadWaiters.removeAll()
        for waiter in releaseWaiters {
            waiter.resume()
        }
        releaseWaiters.removeAll()
    }

    func waitForSecondReadAttempt() async {
        if secondReadAttempted {
            return
        }
        await withCheckedContinuation { continuation in
            secondReadWaiters.append(continuation)
        }
    }

    func releaseSecondChunk() {
        secondChunkReleased = true
        for waiter in releaseWaiters {
            waiter.resume()
        }
        releaseWaiters.removeAll()
    }
}

final class XargsCollectingOutputStream: MSPCommandOutputStream, @unchecked Sendable {
    private let storage = XargsCollectingOutputStreamStorage()

    func write(_ data: Data) async throws {
        await storage.write(data)
    }

    func closeWrite() async {
        await storage.closeWrite()
    }

    func string() async -> String {
        await storage.string()
    }
}

private actor XargsCollectingOutputStreamStorage {
    private var collected = Data()

    func write(_ chunk: Data) {
        collected.append(chunk)
    }

    func closeWrite() {}

    func string() -> String {
        String(decoding: collected, as: UTF8.self)
    }
}

private struct XargsWorkspace: MSPWorkspace {
    let rootPath = "/"
    let fileSystem: any MSPWorkspaceFileSystem
}

private final class XargsStreamingFileSystem: MSPWorkspaceFileSystem, @unchecked Sendable {
    let policy = MSPWorkspaceFileSystemPolicy.default
    var files: [String: Data]

    init(files: [String: Data]) {
        self.files = files
    }

    func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
        MSPResolvedPath(virtualPath: MSPWorkspacePathResolver.normalize(path, from: currentDirectory))
    }

    func stat(_ path: String, from currentDirectory: String) throws -> MSPFileInfo {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        if let data = files[virtualPath] {
            return MSPFileInfo(virtualPath: virtualPath, type: .regularFile, size: Int64(data.count))
        }
        if virtualPath == "/" {
            return MSPFileInfo(virtualPath: "/", type: .directory)
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
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        return data
    }

    func readFileRange(_ path: String, from currentDirectory: String, offset: UInt64, length: Int) throws -> Data {
        let data = try readFile(path, from: currentDirectory)
        guard length > 0, offset < UInt64(data.count) else {
            return Data()
        }
        let start = Int(offset)
        let end = min(data.count, start + length)
        return data.subdata(in: start..<end)
    }

    func writeFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions
    ) throws {
        files[try resolve(path, from: currentDirectory).virtualPath] = data
    }

    func appendFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions,
        creationMode: UInt16?
    ) throws {
        files[try resolve(path, from: currentDirectory).virtualPath, default: Data()].append(data)
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
        throw MSPWorkspaceFileSystemError.io(path: sourcePath, operation: "link")
    }

    func createSymbolicLink(target: String, at linkPath: String, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.io(path: linkPath, operation: "symlink")
    }

    func chmod(_ path: String, mode: UInt16, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.io(path: path, operation: "chmod")
    }
}
