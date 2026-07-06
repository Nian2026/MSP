import Foundation
import MSPCore
import MSPPOSIXCore
import XCTest

extension MSPCore100FilesystemCommandTests {
    func testRmdirRemovesOnlyEmptyDirectoriesAndReportsNonEmpty() async throws {
        let workspace = Core100FilesystemTestWorkspace(entries: [
            "/": .directory(mode: 0o777),
            "/empty": .directory(mode: 0o755),
            "/full": .directory(mode: 0o755),
            "/full/file": .file(Data("x".utf8), mode: 0o644)
        ])

        let empty = try await MSPRmdirCommand().run(
            invocation: MSPCommandInvocation(name: "rmdir", arguments: ["empty"]),
            context: context(workspace)
        )
        XCTAssertEqual(empty.exitCode, 0)
        XCTAssertNil(workspace.fileSystemBox.entries["/empty"])

        let full = try await MSPRmdirCommand().run(
            invocation: MSPCommandInvocation(name: "rmdir", arguments: ["full"]),
            context: context(workspace)
        )
        XCTAssertEqual(full.exitCode, 1)
        XCTAssertEqual(full.stderr, "rmdir: failed to remove 'full': Directory not empty\n")
        XCTAssertNotNil(workspace.fileSystemBox.entries["/full"])
    }

    func testMkdirModeAndExistingDirectoryDiagnostic() async throws {
        let workspace = Core100FilesystemTestWorkspace(entries: [
            "/": .directory(mode: 0o777)
        ])

        let created = try await MSPMkdirCommand().run(
            invocation: MSPCommandInvocation(name: "mkdir", arguments: ["-m", "700", "d"]),
            context: context(workspace)
        )
        XCTAssertEqual(created.exitCode, 0)
        XCTAssertEqual(created.stderr, "")
        XCTAssertEqual(workspace.fileSystemBox.mode("/d"), 0o700)

        let existing = try await MSPMkdirCommand().run(
            invocation: MSPCommandInvocation(name: "mkdir", arguments: ["d"]),
            context: context(workspace)
        )
        XCTAssertEqual(existing.exitCode, 1)
        XCTAssertEqual(existing.stderr, "mkdir: cannot create directory \u{2018}d\u{2019}: File exists\n")
    }

    func testMkdirVerboseReportsCreatedDirectories() async throws {
        let workspace = Core100FilesystemTestWorkspace(entries: [
            "/": .directory(mode: 0o777)
        ])

        let created = try await MSPMkdirCommand().run(
            invocation: MSPCommandInvocation(name: "mkdir", arguments: ["-v", "d"]),
            context: context(workspace)
        )

        XCTAssertEqual(created.exitCode, 0)
        XCTAssertEqual(created.stdout, "mkdir: created directory \u{2018}d\u{2019}\n")
        XCTAssertEqual(workspace.fileSystemBox.mode("/d"), 0o755)
    }

    func testRmDirRemovesOnlyEmptyDirectoryAndReportsVerboseSuccess() async throws {
        let workspace = Core100FilesystemTestWorkspace(entries: [
            "/": .directory(mode: 0o777),
            "/empty": .directory(mode: 0o755),
            "/full": .directory(mode: 0o755),
            "/full/file": .file(Data(), mode: 0o644)
        ])

        let empty = try await MSPRmCommand().run(
            invocation: MSPCommandInvocation(name: "rm", arguments: ["-dv", "empty"]),
            context: context(workspace)
        )
        XCTAssertEqual(empty.exitCode, 0)
        XCTAssertEqual(empty.stdout, "removed 'empty'\n")
        XCTAssertNil(workspace.fileSystemBox.entries["/empty"])

        let full = try await MSPRmCommand().run(
            invocation: MSPCommandInvocation(name: "rm", arguments: ["-d", "full"]),
            context: context(workspace)
        )
        XCTAssertEqual(full.exitCode, 1)
        XCTAssertEqual(full.stderr, "rm: cannot remove 'full': Directory not empty\n")
        XCTAssertNotNil(workspace.fileSystemBox.entries["/full"])
    }

    func testRmdirDeprecatedPathAliasRemovesParents() async throws {
        let workspace = Core100FilesystemTestWorkspace(entries: [
            "/": .directory(mode: 0o777),
            "/a": .directory(mode: 0o755),
            "/a/b": .directory(mode: 0o755)
        ])

        let result = try await MSPRmdirCommand().run(
            invocation: MSPCommandInvocation(name: "rmdir", arguments: ["--path", "a/b"]),
            context: context(workspace)
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNil(workspace.fileSystemBox.entries["/a/b"])
        XCTAssertNil(workspace.fileSystemBox.entries["/a"])
    }
}
