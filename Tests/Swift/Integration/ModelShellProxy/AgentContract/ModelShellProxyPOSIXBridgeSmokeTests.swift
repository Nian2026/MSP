import Foundation
import MSPAgentBridge
import XCTest
import ModelShellProxy

extension ModelShellProxyPOSIXCommandSmokeTests {
    func testPOSIXCoreErrorsUseVirtualPathsOnly() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let result = await shell.run("cat missing.txt")

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.stderr, "cat: missing.txt: No such file or directory\n")
        XCTAssertFalse(result.stderr.contains(rootURL.path))
    }

    func testExecCommandBridgeRunsPOSIXCoreAsPlainText() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )
        try "bridge\n".write(
            to: rootURL.appendingPathComponent("docs/message.txt"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let text = try await shell
            .execCommandBridge()
            .call(arguments: ["cmd": "cat docs/message.txt"])

        XCTAssertEqual(
            text,
            "Wall time: 0.0000 seconds\n" +
            "Process exited with code 0\n" +
            "Output:\n" +
            "bridge\n"
        )
        XCTAssertFalse(text.contains(#""stdout""#))
        XCTAssertFalse(text.contains(rootURL.path))
    }

    func testExecCommandBridgeRunsSequentialPOSIXCoreFindAsPlainText() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )
        try "bridge\n".write(
            to: rootURL.appendingPathComponent("docs/message.txt"),
            atomically: true,
            encoding: .utf8
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let text = try await shell
            .execCommandBridge()
            .call(arguments: ["cmd": "pwd; find /docs -maxdepth 1 -type f -print"])

        XCTAssertEqual(
            text,
            "Wall time: 0.0000 seconds\n" +
            "Process exited with code 0\n" +
            "Output:\n" +
            "/\n/docs/message.txt\n"
        )
        XCTAssertFalse(text.contains(#""stdout""#))
        XCTAssertFalse(text.contains(rootURL.path))
    }
}
