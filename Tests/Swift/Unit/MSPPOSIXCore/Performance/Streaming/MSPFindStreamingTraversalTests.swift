import Foundation
import MSPCore
import MSPPOSIXCore
import XCTest

final class MSPFindStreamingTraversalTests: XCTestCase {
    func testFindUsesWorkspaceDirectoryEnumerationInsteadOfEagerListDirectory() async throws {
        let fileSystem = StreamingTraversalFileSystem()
        let workspace = StreamingTraversalWorkspace(fileSystem: fileSystem)
        let context = MSPCommandContext(workspace: workspace, currentDirectory: "/")

        let result = try await MSPFindCommand().run(
            invocation: MSPCommandInvocation(
                name: "find",
                arguments: ["/", "-type", "f", "-print"]
            ),
            context: context
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.stdout, "/album/a.jpg\n/album/b.jpg\n")
        XCTAssertEqual(fileSystem.listDirectoryCallCount, 0)
        XCTAssertEqual(fileSystem.enumeratedDirectories, ["/", "/album", "/empty"])
    }

    func testFindEmptyPredicateUsesDirectoryEnumerationInsteadOfEagerListDirectory() async throws {
        let fileSystem = StreamingTraversalFileSystem()
        let workspace = StreamingTraversalWorkspace(fileSystem: fileSystem)
        let context = MSPCommandContext(workspace: workspace, currentDirectory: "/")

        let result = try await MSPFindCommand().run(
            invocation: MSPCommandInvocation(
                name: "find",
                arguments: ["/", "-empty", "-print"]
            ),
            context: context
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.stdout, "/empty\n")
        XCTAssertEqual(fileSystem.listDirectoryCallCount, 0)
    }

    func testFindPrunePreventsDescent() async throws {
        let fileSystem = StreamingTraversalFileSystem()
        let workspace = StreamingTraversalWorkspace(fileSystem: fileSystem)
        let context = MSPCommandContext(workspace: workspace, currentDirectory: "/")

        let result = try await MSPFindCommand().run(
            invocation: MSPCommandInvocation(
                name: "find",
                arguments: ["/", "-path", "/album", "-prune", "-o", "-type", "f", "-print"]
            ),
            context: context
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(fileSystem.listDirectoryCallCount, 0)
        XCTAssertEqual(fileSystem.enumeratedDirectories, ["/", "/empty"])
    }

    func testFindDeleteFailureSetsExitStatus() async throws {
        let fileSystem = StreamingTraversalFileSystem()
        let workspace = StreamingTraversalWorkspace(fileSystem: fileSystem)
        let context = MSPCommandContext(workspace: workspace, currentDirectory: "/")

        let result = try await MSPFindCommand().run(
            invocation: MSPCommandInvocation(
                name: "find",
                arguments: ["/album/a.jpg", "-delete"]
            ),
            context: context
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "find: cannot delete \u{2018}/album/a.jpg\u{2019}: Permission denied\n")
        XCTAssertEqual(fileSystem.listDirectoryCallCount, 0)
        XCTAssertEqual(fileSystem.enumeratedDirectories, [])
    }

    func testFindBatchedExecFlushesBeforeAccumulatingAllMatches() async throws {
        let fileSystem = ManyFileFindFileSystem(fileCount: 300)
        let workspace = StreamingTraversalWorkspace(fileSystem: fileSystem)
        let recorder = FindSubcommandRecorder()
        let context = MSPCommandContext(
            workspace: workspace,
            currentDirectory: "/",
            subcommandRunner: { invocation, _ in
                await recorder.record(invocation)
                return .success()
            }
        )

        let result = try await MSPFindCommand().run(
            invocation: MSPCommandInvocation(
                name: "find",
                arguments: ["/", "-type", "f", "-exec", "printf", "%s\n", "{}", "+"]
            ),
            context: context
        )

        let invocations = await recorder.invocations()
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(fileSystem.listDirectoryCallCount, 0)
        XCTAssertEqual(fileSystem.enumeratedEntryCount, 300)
        XCTAssertGreaterThan(invocations.count, 1)
        XCTAssertEqual(invocations.map(\.name), Array(repeating: "printf", count: invocations.count))
        XCTAssertTrue(invocations.allSatisfy { invocation in
            max(0, invocation.arguments.count - 1) <= 128
        })
        XCTAssertEqual(invocations.reduce(0) { total, invocation in
            total + max(0, invocation.arguments.count - 1)
        }, 300)
        XCTAssertEqual(fileSystem.typedEnumerationOptions, [])
    }

    func testFindDirectoryTypePushesFilterToTypedDirectoryEnumeration() async throws {
        let fileSystem = ManyFileFindFileSystem(fileCount: 300)
        let workspace = StreamingTraversalWorkspace(fileSystem: fileSystem)
        let context = MSPCommandContext(workspace: workspace, currentDirectory: "/")

        let result = try await MSPFindCommand().run(
            invocation: MSPCommandInvocation(
                name: "find",
                arguments: ["/", "-type", "d", "-print"]
            ),
            context: context
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.stdout, "/\n")
        XCTAssertEqual(fileSystem.listDirectoryCallCount, 0)
        XCTAssertEqual(fileSystem.enumeratedEntryCount, 0)
        XCTAssertEqual(
            fileSystem.typedEnumerationOptions,
            [MSPDirectoryEnumerationOptions(typeFilter: [.directory])]
        )
    }

    func testFindTerminalFileTypePushesFilterWhenMaxDepthPreventsDescent() async throws {
        let fileSystem = ManyFileFindFileSystem(fileCount: 3)
        let workspace = StreamingTraversalWorkspace(fileSystem: fileSystem)
        let context = MSPCommandContext(workspace: workspace, currentDirectory: "/")

        let result = try await MSPFindCommand().run(
            invocation: MSPCommandInvocation(
                name: "find",
                arguments: ["/", "-maxdepth", "1", "-type", "f", "-print"]
            ),
            context: context
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.stdout, "/file-000.txt\n/file-001.txt\n/file-002.txt\n")
        XCTAssertEqual(fileSystem.listDirectoryCallCount, 0)
        XCTAssertEqual(fileSystem.enumeratedEntryCount, 3)
        XCTAssertEqual(fileSystem.batchEnumerationCallCount, 1)
        XCTAssertEqual(
            fileSystem.batchEnumerationOptions,
            [MSPDirectoryEnumerationOptions(typeFilter: [.regularFile])]
        )
    }

    func testFindLeafPrintfUsesDirectoryBatchesForMetadataOnlyExpressions() async throws {
        let fileSystem = ManyFileFindFileSystem(fileCount: 2_500)
        let workspace = StreamingTraversalWorkspace(fileSystem: fileSystem)
        let context = MSPCommandContext(workspace: workspace, currentDirectory: "/")

        let result = try await MSPFindCommand().run(
            invocation: MSPCommandInvocation(
                name: "find",
                arguments: ["/", "-maxdepth", "1", "-type", "f", "-printf", "%f\n"]
            ),
            context: context
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        let lines = result.stdout.split(separator: "\n")
        XCTAssertEqual(lines.count, 2_500)
        XCTAssertEqual(lines.first, "file-000.txt")
        XCTAssertEqual(lines.last, "file-2499.txt")
        XCTAssertEqual(fileSystem.listDirectoryCallCount, 0)
        XCTAssertEqual(fileSystem.typedEnumerationOptions, [])
        XCTAssertEqual(fileSystem.batchEnumerationOptions, [
            MSPDirectoryEnumerationOptions(typeFilter: [.regularFile])
        ])
        XCTAssertEqual(fileSystem.batchSizes, [1024, 1024, 452])
    }

    func testStreamingFindBuffersLargeStdoutWrites() async throws {
        let fileSystem = ManyFileFindFileSystem(fileCount: 10_000)
        let workspace = StreamingTraversalWorkspace(fileSystem: fileSystem)
        let output = CountingOutputStream()
        let context = MSPCommandContext(
            workspace: workspace,
            currentDirectory: "/",
            standardOutputStream: output
        )

        let result = try await MSPFindCommand().runStreaming(
            invocation: MSPCommandInvocation(
                name: "find",
                arguments: ["/", "-maxdepth", "1", "-type", "f", "-print"]
            ),
            context: context
        )

        let outputText = String(decoding: await output.data(), as: UTF8.self)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(outputText.split(separator: "\n").count, 10_000)
        XCTAssertTrue(outputText.hasPrefix("/file-000.txt\n"))
        let writeCount = await output.writeCount()
        XCTAssertLessThan(writeCount, 100)
    }
}

private actor FindSubcommandRecorder {
    private var recordedInvocations: [MSPCommandInvocation] = []

    func record(_ invocation: MSPCommandInvocation) {
        recordedInvocations.append(invocation)
    }

    func invocations() -> [MSPCommandInvocation] {
        recordedInvocations
    }
}

private final class ManyFileFindFileSystem: MSPWorkspaceBatchDirectoryEnumerating, @unchecked Sendable {
    let policy = MSPWorkspaceFileSystemPolicy.default
    private let fileCount: Int
    private(set) var listDirectoryCallCount = 0
    private(set) var enumeratedEntryCount = 0
    private(set) var typedEnumerationOptions: [MSPDirectoryEnumerationOptions] = []
    private(set) var batchEnumerationCallCount = 0
    private(set) var batchEnumerationOptions: [MSPDirectoryEnumerationOptions] = []
    private(set) var batchSizes: [Int] = []

    init(fileCount: Int) {
        self.fileCount = fileCount
    }

    func resolve(_ path: String, from currentDirectory: String) throws -> MSPResolvedPath {
        MSPResolvedPath(virtualPath: normalize(path, from: currentDirectory))
    }

    func stat(_ path: String, from currentDirectory: String) throws -> MSPFileInfo {
        let virtualPath = normalize(path, from: currentDirectory)
        if virtualPath == "/" {
            return MSPFileInfo(virtualPath: "/", type: .directory, permissions: 0o755)
        }
        guard fileIndex(for: virtualPath) != nil else {
            throw MSPWorkspaceFileSystemError.notFound(virtualPath)
        }
        return MSPFileInfo(virtualPath: virtualPath, type: .regularFile, size: 1, permissions: 0o644)
    }

    func listDirectory(_ path: String, from currentDirectory: String) throws -> [MSPDirectoryEntry] {
        listDirectoryCallCount += 1
        throw MSPWorkspaceFileSystemError.io(
            path: normalize(path, from: currentDirectory),
            operation: "eager-list-forbidden"
        )
    }

    func enumerateDirectory(
        _ path: String,
        from currentDirectory: String,
        visitor: (MSPDirectoryEntry) async throws -> Bool
    ) async throws {
        try await enumerateGeneratedFiles(
            path,
            from: currentDirectory,
            options: .all,
            visitor: visitor
        )
    }

    func enumerateDirectory(
        _ path: String,
        from currentDirectory: String,
        options: MSPDirectoryEnumerationOptions,
        visitor: (MSPDirectoryEntry) async throws -> Bool
    ) async throws {
        typedEnumerationOptions.append(options)
        try await enumerateGeneratedFiles(
            path,
            from: currentDirectory,
            options: options,
            visitor: visitor
        )
    }

    func enumerateDirectoryBatches(
        _ path: String,
        from currentDirectory: String,
        options: MSPDirectoryEnumerationOptions,
        batchSize: Int,
        visitor: ([MSPDirectoryEntry]) async throws -> Bool
    ) async throws {
        batchEnumerationCallCount += 1
        batchEnumerationOptions.append(options)
        let virtualPath = normalize(path, from: currentDirectory)
        guard virtualPath == "/" else {
            throw MSPWorkspaceFileSystemError.notDirectory(virtualPath)
        }
        let resolvedBatchSize = max(1, batchSize)
        var batch: [MSPDirectoryEntry] = []
        batch.reserveCapacity(resolvedBatchSize)
        for index in 0..<fileCount {
            let filePath = String(format: "/file-%03d.txt", index)
            let entry = MSPDirectoryEntry(
                name: String(filePath.dropFirst()),
                info: MSPFileInfo(virtualPath: filePath, type: .regularFile, size: 1, permissions: 0o644)
            )
            guard options.includes(entry.type) else {
                continue
            }
            enumeratedEntryCount += 1
            batch.append(entry)
            if batch.count >= resolvedBatchSize {
                batchSizes.append(batch.count)
                guard try await visitor(batch) else {
                    return
                }
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty {
            batchSizes.append(batch.count)
            _ = try await visitor(batch)
        }
    }

    private func enumerateGeneratedFiles(
        _ path: String,
        from currentDirectory: String,
        options: MSPDirectoryEnumerationOptions,
        visitor: (MSPDirectoryEntry) async throws -> Bool
    ) async throws {
        let virtualPath = normalize(path, from: currentDirectory)
        guard virtualPath == "/" else {
            throw MSPWorkspaceFileSystemError.notDirectory(virtualPath)
        }
        for index in 0..<fileCount {
            let filePath = String(format: "/file-%03d.txt", index)
            let entry = MSPDirectoryEntry(
                name: String(filePath.dropFirst()),
                info: MSPFileInfo(virtualPath: filePath, type: .regularFile, size: 1, permissions: 0o644)
            )
            guard options.includes(entry.type) else {
                continue
            }
            enumeratedEntryCount += 1
            guard try await visitor(entry) else {
                return
            }
        }
    }

    func readSymbolicLink(_ path: String, from currentDirectory: String) throws -> String {
        throw MSPWorkspaceFileSystemError.notSymbolicLink(normalize(path, from: currentDirectory))
    }

    func readFile(_ path: String, from currentDirectory: String) throws -> Data {
        throw MSPWorkspaceFileSystemError.notFound(normalize(path, from: currentDirectory))
    }

    func writeFile(
        _ path: String,
        data: Data,
        from currentDirectory: String,
        options: MSPFileWriteOptions
    ) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(normalize(path, from: currentDirectory))
    }

    func createDirectory(_ path: String, from currentDirectory: String, intermediates: Bool) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(normalize(path, from: currentDirectory))
    }

    func touch(_ path: String, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(normalize(path, from: currentDirectory))
    }

    func remove(_ path: String, from currentDirectory: String, recursive: Bool) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(normalize(path, from: currentDirectory))
    }

    func copy(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileCopyOptions
    ) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(normalize(destinationPath, from: currentDirectory))
    }

    func move(
        _ sourcePath: String,
        to destinationPath: String,
        from currentDirectory: String,
        options: MSPFileMoveOptions
    ) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(normalize(destinationPath, from: currentDirectory))
    }

    func createHardLink(source sourcePath: String, at linkPath: String, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(normalize(linkPath, from: currentDirectory))
    }

    func createSymbolicLink(target: String, at linkPath: String, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(normalize(linkPath, from: currentDirectory))
    }

    func chmod(_ path: String, mode: UInt16, from currentDirectory: String) throws {
        throw MSPWorkspaceFileSystemError.accessDenied(normalize(path, from: currentDirectory))
    }

    private func fileIndex(for virtualPath: String) -> Int? {
        guard virtualPath.hasPrefix("/file-"),
              virtualPath.hasSuffix(".txt"),
              let index = Int(virtualPath.dropFirst("/file-".count).dropLast(".txt".count)),
              index >= 0,
              index < fileCount else {
            return nil
        }
        return index
    }

    private func normalize(_ path: String, from currentDirectory: String) -> String {
        MSPWorkspacePathResolver.normalize(path, from: currentDirectory)
    }
}

private final class CountingOutputStream: MSPCommandOutputStream {
    private let storage = CountingOutputStreamStorage()

    func write(_ data: Data) async throws {
        await storage.write(data)
    }

    func data() async -> Data {
        await storage.data()
    }

    func writeCount() async -> Int {
        await storage.writeCount()
    }
}

private actor CountingOutputStreamStorage {
    private var buffer = Data()
    private var writes = 0

    func write(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        writes += 1
        buffer.append(data)
    }

    func data() -> Data {
        buffer
    }

    func writeCount() -> Int {
        writes
    }
}
