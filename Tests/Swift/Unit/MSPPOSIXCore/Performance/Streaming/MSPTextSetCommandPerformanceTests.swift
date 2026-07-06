import Foundation
import XCTest
import MSPCore
import MSPPOSIXCore

final class MSPTextSetCommandPerformanceTests: XCTestCase {
    func testCutStreamsRecordsAndStopsAfterBrokenPipe() async throws {
        let normalOutput = MSPCommandOutputBuffer()
        _ = try await MSPCutCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "cut", arguments: ["-d", ":", "-f", "1"]),
            context: MSPCommandContext(
                standardInputStream: CountingChunkInputStream([
                    Data("alpha:1\n".utf8),
                    Data("beta:2\n".utf8)
                ]),
                standardOutputStream: normalOutput
            )
        )
        let normalData = await normalOutput.data()
        XCTAssertEqual(normalData, Data("alpha\nbeta\n".utf8))

        let input = CountingChunkInputStream((0..<100).map { Data("row\($0):value\n".utf8) })
        let breakingOutput = BreakingOutputStream(failOnWrite: 1)
        let result = try await MSPCutCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "cut", arguments: ["-d", ":", "-f", "1"]),
            context: MSPCommandContext(
                standardInputStream: input,
                standardOutputStream: breakingOutput
            )
        )

        XCTAssertEqual(result.exitCode, 0)
        let readCount = await input.readCount
        let writeCount = await breakingOutput.writeCount
        XCTAssertLessThan(readCount, 100)
        XCTAssertEqual(writeCount, 1)
    }

    func testTrStreamsChunksAndStopsAfterBrokenPipe() async throws {
        let normalOutput = MSPCommandOutputBuffer()
        _ = try await MSPTrCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "tr", arguments: ["-s", "ab"]),
            context: MSPCommandContext(
                standardInputStream: CountingChunkInputStream([
                    Data("aa".utf8),
                    Data("bb".utf8),
                    Data("a".utf8)
                ]),
                standardOutputStream: normalOutput
            )
        )
        let normalData = await normalOutput.data()
        XCTAssertEqual(normalData, Data("aba".utf8))

        let input = CountingChunkInputStream((0..<100).map { _ in Data("abc\n".utf8) })
        let breakingOutput = BreakingOutputStream(failOnWrite: 1)
        let result = try await MSPTrCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "tr", arguments: ["a-z", "A-Z"]),
            context: MSPCommandContext(
                standardInputStream: input,
                standardOutputStream: breakingOutput
            )
        )

        XCTAssertEqual(result.exitCode, 0)
        let readCount = await input.readCount
        let writeCount = await breakingOutput.writeCount
        XCTAssertLessThan(readCount, 100)
        XCTAssertEqual(writeCount, 1)
    }

    func testUniqStreamsAdjacentRunsAndStopsAfterBrokenPipe() async throws {
        let normalOutput = MSPCommandOutputBuffer()
        _ = try await MSPUniqCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "uniq", arguments: []),
            context: MSPCommandContext(
                standardInputStream: CountingChunkInputStream([
                    Data("alpha\n".utf8),
                    Data("alpha\n".utf8),
                    Data("beta\n".utf8)
                ]),
                standardOutputStream: normalOutput
            )
        )
        let normalData = await normalOutput.data()
        XCTAssertEqual(normalData, Data("alpha\nbeta\n".utf8))

        let input = CountingChunkInputStream((0..<100).map { Data("row\($0)\n".utf8) })
        let breakingOutput = BreakingOutputStream(failOnWrite: 1)
        let result = try await MSPUniqCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "uniq", arguments: []),
            context: MSPCommandContext(
                standardInputStream: input,
                standardOutputStream: breakingOutput
            )
        )

        XCTAssertEqual(result.exitCode, 0)
        let readCount = await input.readCount
        let writeCount = await breakingOutput.writeCount
        XCTAssertLessThan(readCount, 100)
        XCTAssertEqual(writeCount, 1)
    }

    func testJoinMergesDuplicateSortedGroupsInInputOrder() async throws {
        let workspace = TextSetWorkspace(files: [
            "/left.txt": Data("a left1\na left2\nb left3\n".utf8),
            "/right.txt": Data("a right1\na right2\nb right3\n".utf8)
        ])

        let result = await runCommand("join", ["/left.txt", "/right.txt"], workspace: workspace)

        XCTAssertEqual(
            result.stdout,
            "a left1 right1\n"
                + "a left1 right2\n"
                + "a left2 right1\n"
                + "a left2 right2\n"
                + "b left3 right3\n"
        )
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

private final class CountingChunkInputStream: MSPCommandInputStream, @unchecked Sendable {
    private let storage: CountingChunkInputStreamStorage

    init(_ chunks: [Data]) {
        self.storage = CountingChunkInputStreamStorage(chunks: chunks)
    }

    func read(maxBytes: Int) async throws -> Data? {
        await storage.read()
    }

    func closeRead() async {
        await storage.close()
    }

    var readCount: Int {
        get async {
            await storage.readCount
        }
    }
}

private actor CountingChunkInputStreamStorage {
    private var chunks: [Data]
    private var closed = false
    private(set) var readCount = 0

    init(chunks: [Data]) {
        self.chunks = chunks
    }

    func read() -> Data? {
        guard !closed, !chunks.isEmpty else {
            return nil
        }
        readCount += 1
        return chunks.removeFirst()
    }

    func close() {
        closed = true
        chunks.removeAll()
    }
}

private final class BreakingOutputStream: MSPCommandOutputStream, @unchecked Sendable {
    private let storage: BreakingOutputStreamStorage

    init(failOnWrite: Int) {
        self.storage = BreakingOutputStreamStorage(failOnWrite: failOnWrite)
    }

    func write(_ data: Data) async throws {
        try await storage.write(data)
    }

    func closeWrite() async {}

    var writeCount: Int {
        get async {
            await storage.writeCount
        }
    }
}

private actor BreakingOutputStreamStorage {
    private let failOnWrite: Int
    private(set) var writeCount = 0

    init(failOnWrite: Int) {
        self.failOnWrite = failOnWrite
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else {
            return
        }
        writeCount += 1
        if writeCount >= failOnWrite {
            throw MSPCommandStreamError.brokenPipe
        }
    }
}

private struct TextSetWorkspace: MSPWorkspace {
    let rootPath = "/"
    let fileSystem: any MSPWorkspaceFileSystem

    init(files: [String: Data]) {
        self.fileSystem = TextSetWorkspaceFileSystem(files: files)
    }
}

private struct TextSetWorkspaceFileSystem: MSPWorkspaceFileSystem {
    let policy = MSPWorkspaceFileSystemPolicy.default
    var files: [String: Data]

    func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
        MSPResolvedPath(virtualPath: MSPWorkspacePathResolver.normalize(path, from: currentDirectory))
    }

    func stat(_ path: String, from currentDirectory: String) throws -> MSPFileInfo {
        let virtualPath = try resolve(path, from: currentDirectory).virtualPath
        if let data = files[virtualPath] {
            return MSPFileInfo(virtualPath: virtualPath, type: .regularFile, size: Int64(data.count))
        }
        if virtualPath == "/" {
            return MSPFileInfo(virtualPath: virtualPath, type: .directory)
        }
        throw MSPWorkspaceFileSystemError.notFound(virtualPath)
    }

    func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String {
        throw MSPWorkspaceFileSystemError.notSymbolicLink(try resolve(path, from: currentDirectory).virtualPath)
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

    func writeFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions
    ) throws {}

    func createDirectory(_ path: String, from currentDirectory: String, intermediates: Bool) throws {}

    func touch(_ path: String, from currentDirectory: String) throws {}

    func remove(_ path: String, from currentDirectory: String, recursive: Bool) throws {}

    func copy(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileCopyOptions
    ) throws {}

    func move(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileMoveOptions
    ) throws {}
}
