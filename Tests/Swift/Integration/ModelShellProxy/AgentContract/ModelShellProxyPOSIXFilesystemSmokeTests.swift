import Foundation
import XCTest
import ModelShellProxy

extension ModelShellProxyPOSIXCommandSmokeTests {
    func testPOSIXCoreCanCopyMoveRemoveAndEvaluateConditions() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )
        try "alpha\n".write(
            to: rootURL.appendingPathComponent("docs/a.txt"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let echo = await shell.run("echo hello msp")
        let printf = await shell.run("printf '%s:%03d\\n' item 7")
        let copy = await shell.run("cp docs/a.txt docs/b.txt")
        let move = await shell.run("mv docs/b.txt docs/c.txt")
        let testFile = await shell.run("test -f docs/c.txt")
        let bracket = await shell.run("[ 5 -gt 3 ]")
        let falseCommand = await shell.run("false")
        let remove = await shell.run("rm docs/a.txt")
        let list = await shell.run("ls docs")

        XCTAssertEqual(echo.stdout, "hello msp\n")
        XCTAssertEqual(printf.stdout, "item:007\n")
        XCTAssertEqual(copy.exitCode, 0)
        XCTAssertEqual(move.exitCode, 0)
        XCTAssertEqual(testFile.exitCode, 0)
        XCTAssertEqual(bracket.exitCode, 0)
        XCTAssertEqual(falseCommand.exitCode, 1)
        XCTAssertEqual(remove.exitCode, 0)
        XCTAssertEqual(list.stdout, "c.txt\n")
    }

    func testPOSIXCoreRemoveDirectoryRequiresRecursiveFlag() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let plainRemove = await shell.run("rm docs")
        let recursiveRemove = await shell.run("rm -r docs")

        XCTAssertEqual(plainRemove.exitCode, 1)
        XCTAssertEqual(plainRemove.stderr, "rm: cannot remove 'docs': Is a directory\n")
        XCTAssertEqual(recursiveRemove.exitCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("docs").path))
    }
}
