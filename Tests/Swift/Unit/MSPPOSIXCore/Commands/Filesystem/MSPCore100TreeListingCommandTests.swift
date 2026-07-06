import Foundation
import MSPCore
import MSPPOSIXCore
import XCTest

extension MSPCore100FilesystemCommandTests {
    func testTreeStreamsTraversalWithoutEagerListDirectory() async throws {
        let workspace = Core100FilesystemTestWorkspace(entries: [
            "/": .directory(mode: 0o777),
            "/a": .directory(mode: 0o755),
            "/a/file": .file(Data(), mode: 0o644),
            "/link": .symlink(target: "a")
        ])

        let result = try await MSPTreeCommand().run(
            invocation: MSPCommandInvocation(name: "tree", arguments: []),
            context: context(workspace)
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.stdout, """
        .
        ├── a
        │   └── file
        └── link -> a

        3 directories, 1 file

        """)
        XCTAssertEqual(workspace.fileSystemBox.listDirectoryCallCount, 0)
        XCTAssertEqual(workspace.fileSystemBox.enumeratedDirectories, ["/", "/a"])
    }

    func testTreeInvalidOptionUsageEndsWithGNUFinalNewline() async throws {
        let workspace = Core100FilesystemTestWorkspace(entries: [
            "/": .directory(mode: 0o777)
        ])

        let result = try await MSPTreeCommand().run(
            invocation: MSPCommandInvocation(name: "tree", arguments: ["-Z"]),
            context: context(workspace)
        )

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.hasSuffix("[--help] [--] [directory ...]\n"))
    }

    func testTreeMultipleRootsNoReportAndOutputFile() async throws {
        let workspace = Core100FilesystemTestWorkspace(entries: [
            "/": .directory(mode: 0o777),
            "/a": .directory(mode: 0o755),
            "/a/file": .file(Data(), mode: 0o644),
            "/b": .directory(mode: 0o755)
        ])

        let result = try await MSPTreeCommand().run(
            invocation: MSPCommandInvocation(
                name: "tree",
                arguments: ["--noreport", "-o", "out.txt", "a", "b"]
            ),
            context: context(workspace)
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(workspace.fileSystemBox.fileData("/out.txt"), Data("""
        a
        └── file
        b

        """.utf8))
    }

    func testDuNullTerminatesRows() async throws {
        let workspace = Core100FilesystemTestWorkspace(entries: [
            "/": .directory(mode: 0o777),
            "/a": .file(Data("abc".utf8), mode: 0o644)
        ])

        let result = try await MSPDuCommand().run(
            invocation: MSPCommandInvocation(name: "du", arguments: ["-0", "-b", "a"]),
            context: context(workspace)
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdoutData, Data("3\ta\0".utf8))
    }

    func testLsZeroTerminatesRows() async throws {
        let workspace = Core100FilesystemTestWorkspace(entries: [
            "/": .directory(mode: 0o777),
            "/b": .file(Data(), mode: 0o644),
            "/a": .file(Data(), mode: 0o644)
        ])

        let result = try await MSPLsCommand().run(
            invocation: MSPCommandInvocation(name: "ls", arguments: ["--zero"]),
            context: context(workspace)
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdoutData, Data("a\0b\0".utf8))
    }
}
