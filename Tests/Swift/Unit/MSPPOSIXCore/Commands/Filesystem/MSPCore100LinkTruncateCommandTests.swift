import Foundation
import MSPCore
import MSPPOSIXCore
import XCTest

extension MSPCore100FilesystemCommandTests {
    func testUnlinkRemovesSymlinkItselfAndRejectsDirectory() async throws {
        let workspace = Core100FilesystemTestWorkspace(entries: [
            "/": .directory(mode: 0o777),
            "/target": .file(Data("target".utf8), mode: 0o644),
            "/link": .symlink(target: "target"),
            "/dir": .directory(mode: 0o755)
        ])

        let link = try await MSPUnlinkCommand().run(
            invocation: MSPCommandInvocation(name: "unlink", arguments: ["link"]),
            context: context(workspace)
        )
        XCTAssertEqual(link.exitCode, 0)
        XCTAssertNil(workspace.fileSystemBox.entries["/link"])
        XCTAssertNotNil(workspace.fileSystemBox.entries["/target"])

        let directory = try await MSPUnlinkCommand().run(
            invocation: MSPCommandInvocation(name: "unlink", arguments: ["dir"]),
            context: context(workspace)
        )
        XCTAssertEqual(directory.exitCode, 1)
        XCTAssertEqual(directory.stderr, "unlink: cannot unlink 'dir': Is a directory\n")
    }

    func testLinkAndUnlinkHelpAndVersion() async throws {
        let workspace = Core100FilesystemTestWorkspace(entries: [
            "/": .directory(mode: 0o777)
        ])

        let linkHelp = try await MSPLinkCommand().run(
            invocation: MSPCommandInvocation(name: "link", arguments: ["--help"]),
            context: context(workspace)
        )
        XCTAssertEqual(linkHelp.exitCode, 0)
        XCTAssertTrue(linkHelp.stdout.hasPrefix("Usage: link FILE1 FILE2\n"))

        let unlinkVersion = try await MSPUnlinkCommand().run(
            invocation: MSPCommandInvocation(name: "unlink", arguments: ["--version"]),
            context: context(workspace)
        )
        XCTAssertEqual(unlinkVersion.exitCode, 0)
        XCTAssertEqual(unlinkVersion.stdout, "unlink (MSP coreutils-compatible) 9.1\n")
    }

    func testTruncateGrowsShrinksAndHonorsNoCreate() async throws {
        let workspace = Core100FilesystemTestWorkspace(entries: [
            "/": .directory(mode: 0o777),
            "/f": .file(Data("abcdef".utf8), mode: 0o644)
        ])

        let shrink = try await MSPTruncateCommand().run(
            invocation: MSPCommandInvocation(name: "truncate", arguments: ["-s", "3", "f"]),
            context: context(workspace)
        )
        XCTAssertEqual(shrink.exitCode, 0)
        XCTAssertEqual(workspace.fileSystemBox.fileData("/f"), Data("abc".utf8))

        let grow = try await MSPTruncateCommand().run(
            invocation: MSPCommandInvocation(name: "truncate", arguments: ["-s", "+2", "f"]),
            context: context(workspace)
        )
        XCTAssertEqual(grow.exitCode, 0)
        XCTAssertEqual(workspace.fileSystemBox.fileData("/f"), Data([0x61, 0x62, 0x63, 0x00, 0x00]))

        let noCreate = try await MSPTruncateCommand().run(
            invocation: MSPCommandInvocation(name: "truncate", arguments: ["-c", "-s", "5", "missing"]),
            context: context(workspace)
        )
        XCTAssertEqual(noCreate.exitCode, 0)
        XCTAssertNil(workspace.fileSystemBox.entries["/missing"])
    }

    func testTruncateRelativeLimitAndRoundingModes() async throws {
        let workspace = Core100FilesystemTestWorkspace(entries: [
            "/": .directory(mode: 0o777),
            "/f": .file(Data("0123456789".utf8), mode: 0o644)
        ])

        let atMost = try await MSPTruncateCommand().run(
            invocation: MSPCommandInvocation(name: "truncate", arguments: ["-s", "<5", "f"]),
            context: context(workspace)
        )
        XCTAssertEqual(atMost.exitCode, 0)
        XCTAssertEqual(workspace.fileSystemBox.fileData("/f")?.count, 5)

        let atLeast = try await MSPTruncateCommand().run(
            invocation: MSPCommandInvocation(name: "truncate", arguments: ["-s", ">8", "f"]),
            context: context(workspace)
        )
        XCTAssertEqual(atLeast.exitCode, 0)
        XCTAssertEqual(workspace.fileSystemBox.fileData("/f")?.count, 8)

        let roundUp = try await MSPTruncateCommand().run(
            invocation: MSPCommandInvocation(name: "truncate", arguments: ["-s", "%6", "f"]),
            context: context(workspace)
        )
        XCTAssertEqual(roundUp.exitCode, 0)
        XCTAssertEqual(workspace.fileSystemBox.fileData("/f")?.count, 12)

        let roundDown = try await MSPTruncateCommand().run(
            invocation: MSPCommandInvocation(name: "truncate", arguments: ["-s", "/5", "f"]),
            context: context(workspace)
        )
        XCTAssertEqual(roundDown.exitCode, 0)
        XCTAssertEqual(workspace.fileSystemBox.fileData("/f")?.count, 10)
    }
}
