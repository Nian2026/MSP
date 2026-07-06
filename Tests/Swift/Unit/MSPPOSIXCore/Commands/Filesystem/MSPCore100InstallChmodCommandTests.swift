import Foundation
import MSPCore
import MSPPOSIXCore
import XCTest

extension MSPCore100FilesystemCommandTests {
    func testInstallCopiesWithModeAndBackupThroughWorkspaceFS() async throws {
        let workspace = Core100FilesystemTestWorkspace(entries: [
            "/": .directory(mode: 0o777),
            "/src": .file(Data("new".utf8), mode: 0o644),
            "/dst": .file(Data("old".utf8), mode: 0o644)
        ])

        let result = try await MSPInstallCommand().run(
            invocation: MSPCommandInvocation(name: "install", arguments: ["-b", "-m", "700", "src", "dst"]),
            context: context(workspace)
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(workspace.fileSystemBox.fileData("/dst"), Data("new".utf8))
        XCTAssertEqual(workspace.fileSystemBox.mode("/dst"), 0o700)
        XCTAssertEqual(workspace.fileSystemBox.fileData("/dst~"), Data("old".utf8))
        XCTAssertEqual(workspace.fileSystemBox.mode("/dst~"), 0o644)
    }

    func testInstallDirectoryCreatesAncestorsWithFinalMode() async throws {
        let workspace = Core100FilesystemTestWorkspace(entries: [
            "/": .directory(mode: 0o777)
        ])

        let result = try await MSPInstallCommand().run(
            invocation: MSPCommandInvocation(name: "install", arguments: ["-d", "-m", "700", "a/b"]),
            context: context(workspace)
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(workspace.fileSystemBox.mode("/a"), 0o755)
        XCTAssertEqual(workspace.fileSystemBox.mode("/a/b"), 0o700)
    }

    func testInstallDirectoryVerboseReportsCreatedDirectory() async throws {
        let workspace = Core100FilesystemTestWorkspace(entries: [
            "/": .directory(mode: 0o777)
        ])

        let result = try await MSPInstallCommand().run(
            invocation: MSPCommandInvocation(name: "install", arguments: ["-dv", "a"]),
            context: context(workspace)
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "install: creating directory 'a'\n")
        XCTAssertEqual(workspace.fileSystemBox.mode("/a"), 0o755)
    }

    func testInstallAcceptsIgnoredCompatibilityAndStripProgramOptions() async throws {
        let workspace = Core100FilesystemTestWorkspace(entries: [
            "/": .directory(mode: 0o777),
            "/src": .file(Data("new".utf8), mode: 0o644)
        ])

        let copy = try await MSPInstallCommand().run(
            invocation: MSPCommandInvocation(
                name: "install",
                arguments: ["-c", "--strip-program", "virtual-strip", "src", "dst"]
            ),
            context: context(workspace)
        )

        XCTAssertEqual(copy.exitCode, 0)
        XCTAssertEqual(copy.stderr, "")
        XCTAssertEqual(workspace.fileSystemBox.fileData("/dst"), Data("new".utf8))
    }

    func testChmodRecursiveUpdatesDescendants() async throws {
        let workspace = Core100FilesystemTestWorkspace(entries: [
            "/": .directory(mode: 0o777),
            "/d": .directory(mode: 0o755),
            "/d/sub": .directory(mode: 0o755),
            "/d/file": .file(Data(), mode: 0o644)
        ])

        let result = try await MSPChmodCommand().run(
            invocation: MSPCommandInvocation(name: "chmod", arguments: ["-R", "700", "d"]),
            context: context(workspace)
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(workspace.fileSystemBox.mode("/d"), 0o700)
        XCTAssertEqual(workspace.fileSystemBox.mode("/d/sub"), 0o700)
        XCTAssertEqual(workspace.fileSystemBox.mode("/d/file"), 0o700)
    }

    func testChmodReferenceVerboseChangesAndSilentModes() async throws {
        let workspace = Core100FilesystemTestWorkspace(entries: [
            "/": .directory(mode: 0o777),
            "/ref": .file(Data(), mode: 0o600),
            "/target": .file(Data(), mode: 0o644)
        ])

        let reference = try await MSPChmodCommand().run(
            invocation: MSPCommandInvocation(name: "chmod", arguments: ["--reference=ref", "-v", "target"]),
            context: context(workspace)
        )

        XCTAssertEqual(reference.exitCode, 0)
        XCTAssertEqual(reference.stderr, "")
        XCTAssertEqual(reference.stdout, "mode of 'target' changed from 0644 to 0600\n")
        XCTAssertEqual(workspace.fileSystemBox.mode("/target"), 0o600)

        let changesOnly = try await MSPChmodCommand().run(
            invocation: MSPCommandInvocation(name: "chmod", arguments: ["-c", "600", "target"]),
            context: context(workspace)
        )
        XCTAssertEqual(changesOnly.exitCode, 0)
        XCTAssertEqual(changesOnly.stdout, "")

        let silentMissing = try await MSPChmodCommand().run(
            invocation: MSPCommandInvocation(name: "chmod", arguments: ["-f", "600", "missing"]),
            context: context(workspace)
        )
        XCTAssertEqual(silentMissing.exitCode, 0)
        XCTAssertEqual(silentMissing.stderr, "")
    }
}
