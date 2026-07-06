import Foundation
import MSPCore
import MSPPOSIXCore
import XCTest

final class MSPStreamingCommandTraversalTests: XCTestCase {
    func testDuComputesDirectorySizesInOneTraversal() async throws {
        let fileSystem = StreamingTraversalFileSystem()
        let workspace = StreamingTraversalWorkspace(fileSystem: fileSystem)
        let context = MSPCommandContext(workspace: workspace, currentDirectory: "/")

        let result = try await MSPDuCommand().run(
            invocation: MSPCommandInvocation(name: "du", arguments: ["/"]),
            context: context
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.stdout, "12\t/album\n4\t/empty\n20\t/\n")
        XCTAssertEqual(fileSystem.listDirectoryCallCount, 0)
        XCTAssertEqual(fileSystem.enumeratedDirectories, [])
        XCTAssertEqual(fileSystem.batchEnumeratedDirectories, ["/", "/album", "/empty"])
        XCTAssertEqual(fileSystem.batchEnumerationOptions, [.all, .all, .all])
        XCTAssertEqual(fileSystem.batchSizes, [2, 2])
    }

    func testDuSummarizeAccumulatesWithoutBuildingChildRows() async throws {
        let fileSystem = StreamingTraversalFileSystem()
        let workspace = StreamingTraversalWorkspace(fileSystem: fileSystem)
        let context = MSPCommandContext(workspace: workspace, currentDirectory: "/")

        let result = try await MSPDuCommand().run(
            invocation: MSPCommandInvocation(name: "du", arguments: ["-s", "/"]),
            context: context
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.stdout, "20\t/\n")
        XCTAssertEqual(fileSystem.listDirectoryCallCount, 0)
        XCTAssertEqual(fileSystem.enumeratedDirectories, [])
        XCTAssertEqual(fileSystem.batchEnumeratedDirectories, ["/", "/album", "/empty"])
        XCTAssertEqual(fileSystem.batchEnumerationOptions, [.all, .all, .all])
        XCTAssertEqual(fileSystem.batchSizes, [2, 2])
    }

    func testRecursiveUnsortedLsStreamsDirectorySectionsWithoutEagerListing() async throws {
        let fileSystem = StreamingTraversalFileSystem()
        let workspace = StreamingTraversalWorkspace(fileSystem: fileSystem)
        let output = MSPCommandOutputBuffer()
        let context = MSPCommandContext(
            workspace: workspace,
            currentDirectory: "/",
            standardOutputStream: output
        )

        let result = try await MSPLsCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "ls", arguments: ["-R", "-U", "/"]),
            context: context
        )

        XCTAssertEqual(result.exitCode, 0)
        let outputText = String(decoding: await output.data(), as: UTF8.self)
        XCTAssertEqual(outputText, """
        /:
        album
        empty

        /album:
        a.jpg
        b.jpg

        /empty:

        """)
        XCTAssertEqual(fileSystem.listDirectoryCallCount, 0)
        XCTAssertEqual(fileSystem.enumeratedDirectories, ["/", "/album", "/empty"])
    }

    func testRgProcessesFilesDuringEnumerationWithoutEagerListDirectory() async throws {
        let fileSystem = StreamingTraversalFileSystem()
        let workspace = StreamingTraversalWorkspace(fileSystem: fileSystem)
        let context = MSPCommandContext(workspace: workspace, currentDirectory: "/")

        let result = try await MSPRgCommand().run(
            invocation: MSPCommandInvocation(name: "rg", arguments: ["-n", "alpha", "/"]),
            context: context
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.stdout, "/album/a.jpg:1:alpha\n")
        XCTAssertEqual(fileSystem.listDirectoryCallCount, 0)
        XCTAssertEqual(fileSystem.enumeratedDirectories, ["/", "/album", "/empty"])
        XCTAssertEqual(fileSystem.readFiles, ["/album/a.jpg", "/album/b.jpg"])
    }

    func testGrepRecursiveQuietStopsTraversalAfterFirstMatch() async throws {
        let fileSystem = StreamingTraversalFileSystem()
        let workspace = StreamingTraversalWorkspace(fileSystem: fileSystem)
        let context = MSPCommandContext(workspace: workspace, currentDirectory: "/")

        let result = try await MSPGrepCommand().run(
            invocation: MSPCommandInvocation(name: "grep", arguments: ["-r", "-q", "alpha", "/"]),
            context: context
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(fileSystem.listDirectoryCallCount, 0)
        XCTAssertEqual(fileSystem.enumeratedDirectories, ["/", "/album"])
        XCTAssertEqual(fileSystem.readFiles, ["/album/a.jpg"])
    }

    func testStreamingGrepMaxCountClosesUpstreamReadSide() async throws {
        let standardInput = ChunkedTestInputStream(chunks: [
            Data("alpha\n".utf8),
            Data("beta\n".utf8),
            Data("alpha\n".utf8)
        ])
        let standardOutput = MSPCommandOutputBuffer()
        let context = MSPCommandContext(
            standardInputStream: standardInput,
            standardOutputStream: standardOutput
        )

        let result = try await MSPGrepCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "grep", arguments: ["-m", "1", "alpha"]),
            context: context
        )

        XCTAssertEqual(result.exitCode, 0)
        let stdout = String(decoding: await standardOutput.data(), as: UTF8.self)
        let readCount = await standardInput.readCount
        let didCloseRead = await standardInput.didCloseRead
        XCTAssertEqual(stdout, "alpha\n")
        XCTAssertEqual(readCount, 1)
        XCTAssertTrue(didCloseRead)
    }
}
