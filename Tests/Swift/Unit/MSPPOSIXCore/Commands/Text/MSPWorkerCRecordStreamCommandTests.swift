import Foundation
import XCTest
import MSPCore
import MSPPOSIXCore

final class MSPWorkerCRecordStreamCommandTests: XCTestCase {
    func testTeeStreamsInputToOutputChunks() async throws {
        let input = ChunkedInputStream(["a\n", "b\n"])
        let output = CollectingOutputStream()

        let result = try await MSPTeeCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "tee"),
            context: MSPCommandContext(
                standardInputStream: input,
                standardOutputStream: output
            )
        )

        let outputText = await output.string()
        let inputReadCount = await input.readCount()
        XCTAssertEqual(outputText, "a\nb\n")
        XCTAssertEqual(inputReadCount, 2)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testCatPlainFileOperandsUseRangeReads() async throws {
        let text = String(repeating: "abcdef0123456789\n", count: 5_000)
        let fileSystem = WorkerCStreamingFileSystem(files: [
            "/big.txt": Data(text.utf8)
        ])

        let result = try await MSPCatCommand().run(
            invocation: MSPCommandInvocation(name: "cat", arguments: ["/big.txt"]),
            context: MSPCommandContext(workspace: WorkerCWorkspace(fileSystem: fileSystem))
        )

        XCTAssertEqual(result.stdout, text)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(fileSystem.readFileCallCount, 0)
        XCTAssertGreaterThan(fileSystem.rangeReadCallCount, 1)
    }

    func testCatPlainFileOperandsStreamThroughRangeReads() async throws {
        let text = String(repeating: "streamed-file-line\n", count: 5_000)
        let fileSystem = WorkerCStreamingFileSystem(files: [
            "/big.txt": Data(text.utf8)
        ])
        let output = CollectingOutputStream()

        let result = try await MSPCatCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "cat", arguments: ["/big.txt"]),
            context: MSPCommandContext(
                workspace: WorkerCWorkspace(fileSystem: fileSystem),
                standardOutputStream: output
            )
        )

        let outputText = await output.string()
        XCTAssertEqual(outputText, text)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(fileSystem.readFileCallCount, 0)
        XCTAssertGreaterThan(fileSystem.rangeReadCallCount, 1)
    }

    func testHeadAndTailFileOperandsUseRangeReads() async throws {
        let lines = (0..<10_000).map { String(format: "line-%05d", $0) }.joined(separator: "\n") + "\n"
        let fileSystem = WorkerCStreamingFileSystem(files: [
            "/big.txt": Data(lines.utf8)
        ])
        let workspace = WorkerCWorkspace(fileSystem: fileSystem)

        let head = try await MSPHeadCommand().run(
            invocation: MSPCommandInvocation(name: "head", arguments: ["-n", "2", "/big.txt"]),
            context: MSPCommandContext(workspace: workspace)
        )
        let rangeReadsAfterHead = fileSystem.rangeReadCallCount

        let tail = try await MSPTailCommand().run(
            invocation: MSPCommandInvocation(name: "tail", arguments: ["-n", "2", "/big.txt"]),
            context: MSPCommandContext(workspace: workspace)
        )

        XCTAssertEqual(head.stdout, "line-00000\nline-00001\n")
        XCTAssertEqual(tail.stdout, "line-09998\nline-09999\n")
        XCTAssertEqual(fileSystem.readFileCallCount, 0)
        XCTAssertGreaterThan(rangeReadsAfterHead, 0)
        XCTAssertGreaterThan(fileSystem.rangeReadCallCount, rangeReadsAfterHead)
        XCTAssertLessThan(fileSystem.rangeReadCallCount, 8)
    }

    func testWcFileOperandsUseRangeReads() async throws {
        let text = String(repeating: "word\n", count: 10_000)
        let fileSystem = WorkerCStreamingFileSystem(files: [
            "/big.txt": Data(text.utf8)
        ])

        let result = try await MSPWcCommand().run(
            invocation: MSPCommandInvocation(name: "wc", arguments: ["-l", "-w", "-c", "/big.txt"]),
            context: MSPCommandContext(workspace: WorkerCWorkspace(fileSystem: fileSystem))
        )

        XCTAssertEqual(result.stdout, "10000 10000 50000 /big.txt\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(fileSystem.readFileCallCount, 0)
        XCTAssertGreaterThan(fileSystem.rangeReadCallCount, 1)
    }

    func testExpandAndUnexpandFileOperandsUseRangeReads() async throws {
        let expandInput = String(repeating: "a\tb\n", count: 10_000)
        let unexpandInput = String(repeating: "    x\n", count: 10_000)
        let fileSystem = WorkerCStreamingFileSystem(files: [
            "/tabs.txt": Data(expandInput.utf8),
            "/spaces.txt": Data(unexpandInput.utf8)
        ])
        let workspace = WorkerCWorkspace(fileSystem: fileSystem)

        let expanded = try await MSPExpandCommand().run(
            invocation: MSPCommandInvocation(name: "expand", arguments: ["-t", "4", "/tabs.txt"]),
            context: MSPCommandContext(workspace: workspace)
        )
        let rangeReadsAfterExpand = fileSystem.rangeReadCallCount
        let unexpanded = try await MSPUnexpandCommand().run(
            invocation: MSPCommandInvocation(name: "unexpand", arguments: ["-t", "4", "/spaces.txt"]),
            context: MSPCommandContext(workspace: workspace)
        )

        XCTAssertTrue(expanded.stdout.hasPrefix("a   b\n"))
        XCTAssertEqual(expanded.stderr, "")
        XCTAssertEqual(expanded.exitCode, 0)
        XCTAssertTrue(unexpanded.stdout.hasPrefix("\tx\n"))
        XCTAssertEqual(unexpanded.stderr, "")
        XCTAssertEqual(unexpanded.exitCode, 0)
        XCTAssertEqual(fileSystem.readFileCallCount, 0)
        XCTAssertGreaterThan(rangeReadsAfterExpand, 1)
        XCTAssertGreaterThan(fileSystem.rangeReadCallCount, rangeReadsAfterExpand)
    }

    func testNlStreamsNumberedRecords() async throws {
        let input = ChunkedInputStream(["a\n", "\n", "b\n"])
        let output = CollectingOutputStream()

        let result = try await MSPNlCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "nl"),
            context: MSPCommandContext(
                standardInputStream: input,
                standardOutputStream: output
            )
        )

        let outputText = await output.string()
        let inputReadCount = await input.readCount()
        XCTAssertEqual(outputText, "     1\ta\n       \n     2\tb\n")
        XCTAssertEqual(inputReadCount, 3)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testNlStreamsFileOperandThroughWorkspaceRangeReads() async throws {
        let fileSystem = WorkerCStreamingFileSystem(files: [
            "/input.txt": Data("a\n\nb\n".utf8)
        ])
        let output = CollectingOutputStream()

        let result = try await MSPNlCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "nl", arguments: ["input.txt"]),
            context: MSPCommandContext(
                workspace: WorkerCWorkspace(fileSystem: fileSystem),
                standardOutputStream: output
            )
        )

        let outputText = await output.string()
        XCTAssertEqual(outputText, "     1\ta\n       \n     2\tb\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(fileSystem.readFileCallCount, 0)
        XCTAssertGreaterThan(fileSystem.rangeReadCallCount, 0)
    }

    func testPasteStreamsMultipleFileOperandsThroughWorkspaceRangeReads() async throws {
        let fileSystem = WorkerCStreamingFileSystem(files: [
            "/left.txt": Data("a\nb\n".utf8),
            "/right.txt": Data("1\n2\n3\n".utf8)
        ])
        let output = CollectingOutputStream()

        let result = try await MSPPasteCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "paste", arguments: ["left.txt", "right.txt"]),
            context: MSPCommandContext(
                workspace: WorkerCWorkspace(fileSystem: fileSystem),
                standardOutputStream: output
            )
        )

        let outputText = await output.string()
        XCTAssertEqual(outputText, "a\t1\nb\t2\n\t3\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(fileSystem.readFileCallCount, 0)
        XCTAssertGreaterThan(fileSystem.rangeReadCallCount, 0)
    }

    func testPasteStreamsRepeatedStandardInputOperandsSequentially() async throws {
        let input = ChunkedInputStream(["a\nb\n", "c\nd\n"])
        let output = CollectingOutputStream()

        let result = try await MSPPasteCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "paste", arguments: ["-", "-"]),
            context: MSPCommandContext(
                standardInputStream: input,
                standardOutputStream: output
            )
        )

        let outputText = await output.string()
        let inputReadCount = await input.readCount()
        XCTAssertEqual(outputText, "a\tb\nc\td\n")
        XCTAssertEqual(inputReadCount, 2)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testPasteStreamsZeroTerminatedSerialStandardInput() async throws {
        let input = ChunkedInputStream(["a\0", "b\0"])
        let output = CollectingOutputStream()

        let result = try await MSPPasteCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "paste", arguments: ["-z", "-s", "-d", ",", "-"]),
            context: MSPCommandContext(
                standardInputStream: input,
                standardOutputStream: output
            )
        )

        let outputText = await output.string()
        let inputReadCount = await input.readCount()
        XCTAssertEqual(outputText, "a,b\0")
        XCTAssertEqual(inputReadCount, 2)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testPasteRunPreservesBinaryRecordsAndEmptyDelimiter() async throws {
        let result = try await MSPPasteCommand().run(
            invocation: MSPCommandInvocation(name: "paste", arguments: ["-s", "-d", "\\0", "-"]),
            context: MSPCommandContext(standardInput: Data([0xff, 0x0a, 0x41, 0x0a]))
        )

        XCTAssertEqual(result.stdoutData, Data([0xff, 0x41, 0x0a]))
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testPasteStreamsZeroTerminatedBinaryRecords() async throws {
        let input = ChunkedInputStream([Data([0xff, 0x00]), Data([0x41, 0x00])])
        let output = CollectingOutputStream()

        let result = try await MSPPasteCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "paste", arguments: ["-z", "-s", "-d", ",", "-"]),
            context: MSPCommandContext(
                standardInputStream: input,
                standardOutputStream: output
            )
        )

        let outputData = await output.data()
        XCTAssertEqual(outputData, Data([0xff, 0x2c, 0x41, 0x00]))
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testTeeStreamsFileTargetsThroughWorkspaceAppend() async throws {
        let fileSystem = WorkerCStreamingFileSystem(files: [:])
        let input = ChunkedInputStream(["a", "b"])
        let output = CollectingOutputStream()

        let result = try await MSPTeeCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "tee", arguments: ["out.txt"]),
            context: MSPCommandContext(
                workspace: WorkerCWorkspace(fileSystem: fileSystem),
                standardInputStream: input,
                standardOutputStream: output
            )
        )

        let outputText = await output.string()
        XCTAssertEqual(outputText, "ab")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(fileSystem.readFileCallCount, 0)
        XCTAssertEqual(fileSystem.writeFilePayloads, [Data()])
        XCTAssertEqual(fileSystem.appendFilePayloads, [Data("a".utf8), Data("b".utf8)])
        XCTAssertEqual(fileSystem.files["/out.txt"], Data("ab".utf8))
    }

    func testTeeAppendModeDoesNotReadExistingFile() async throws {
        let fileSystem = WorkerCStreamingFileSystem(files: [
            "/out.txt": Data("old".utf8)
        ])
        let input = ChunkedInputStream(["+", "new"])
        let output = CollectingOutputStream()

        let result = try await MSPTeeCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "tee", arguments: ["-a", "out.txt"]),
            context: MSPCommandContext(
                workspace: WorkerCWorkspace(fileSystem: fileSystem),
                standardInputStream: input,
                standardOutputStream: output
            )
        )

        let outputText = await output.string()
        XCTAssertEqual(outputText, "+new")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(fileSystem.readFileCallCount, 0)
        XCTAssertEqual(fileSystem.appendFilePayloads, [Data(), Data("+".utf8), Data("new".utf8)])
        XCTAssertEqual(fileSystem.files["/out.txt"], Data("old+new".utf8))
    }

    func testAwkExitStopsReadingUpstreamAndStillRunsEnd() async throws {
        let input = ChunkedInputStream(["one\n", "two\n", "three\n"])
        let output = CollectingOutputStream()

        let result = try await MSPAwkCommand().runStreaming(
            invocation: MSPCommandInvocation(
                name: "awk",
                arguments: ["{ print; exit } END { print \"done\" }"]
            ),
            context: MSPCommandContext(
                standardInputStream: input,
                standardOutputStream: output
            )
        )

        let outputText = await output.string()
        let inputReadCount = await input.readCount()
        let inputIsReadClosed = await input.isReadClosed()
        XCTAssertEqual(outputText, "one\ndone\n")
        XCTAssertEqual(inputReadCount, 1)
        XCTAssertTrue(inputIsReadClosed)
        XCTAssertEqual(result.exitCode, 0)
    }
}

private actor CommandLineCapture {
    private var captured: [String] = []

    func append(_ commandLine: String) {
        captured.append(commandLine)
    }

    func lines() -> [String] {
        captured
    }
}

private final class ChunkedInputStream: MSPCommandInputStream, @unchecked Sendable {
    private let storage: ChunkedInputStreamStorage

    init(_ chunks: [String]) {
        storage = ChunkedInputStreamStorage(chunks.map { Data($0.utf8) })
    }

    init(_ chunks: [Data]) {
        storage = ChunkedInputStreamStorage(chunks)
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

private actor ChunkedInputStreamStorage {
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

private final class CollectingOutputStream: MSPCommandOutputStream, @unchecked Sendable {
    private let storage = CollectingOutputStreamStorage()

    func write(_ data: Data) async throws {
        await storage.write(data)
    }

    func closeWrite() async {
        await storage.closeWrite()
    }

    func string() async -> String {
        await storage.string()
    }

    func data() async -> Data {
        await storage.collectedData()
    }
}

private actor CollectingOutputStreamStorage {
    private var collected = Data()

    func write(_ chunk: Data) {
        collected.append(chunk)
    }

    func closeWrite() {}

    func string() -> String {
        String(decoding: collected, as: UTF8.self)
    }

    func collectedData() -> Data {
        collected
    }
}

private struct WorkerCWorkspace: MSPWorkspace {
    let rootPath = "/"
    let fileSystem: any MSPWorkspaceFileSystem
}

private final class WorkerCStreamingFileSystem: MSPWorkspaceFileSystem, @unchecked Sendable {
    let policy = MSPWorkspaceFileSystemPolicy.default
    var files: [String: Data]
    private(set) var readFileCallCount = 0
    private(set) var rangeReadCallCount = 0
    private(set) var writeFilePayloads: [Data] = []
    private(set) var appendFilePayloads: [Data] = []

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
        readFileCallCount += 1
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard let data = files[virtualPath] else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        return data
    }

    func readFileRange(_ path: String, from currentDirectory: String, offset: UInt64, length: Int) throws -> Data {
        rangeReadCallCount += 1
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        guard let data = files[virtualPath] else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
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
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        files[virtualPath] = data
        writeFilePayloads.append(data)
    }

    func appendFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions,
        creationMode: UInt16?
    ) throws {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        files[virtualPath, default: Data()].append(data)
        appendFilePayloads.append(data)
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
