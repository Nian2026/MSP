import Foundation
import MSPAgentBridge
import XCTest
import ModelShellProxy

extension ModelShellProxyPOSIXCommandSmokeTests {
    func testCustomCommandRunsThroughFacade() async throws {
        let shell = ModelShellProxy()
        try shell.register("hello") { _, arguments in
            .success(stdout: "hello \(arguments.joined(separator: " "))\n")
        }

        let result = await shell.run("hello world")

        XCTAssertEqual(result.stdout, "hello world\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testUnknownCommandReturnsShellStyleExitCode() async {
        let result = await ModelShellProxy().run("missing")

        XCTAssertEqual(result.exitCode, 127)
        XCTAssertEqual(result.stderr, "missing: command not found\n")
    }

    func testExecCommandBridgeRunsCustomCommandAsPlainText() async throws {
        let shell = ModelShellProxy()
        try shell.register("hello") { _, arguments in
            .success(stdout: "hello \(arguments.joined(separator: " "))\n")
        }

        let text = try await shell
            .execCommandBridge()
            .call(arguments: ["cmd": "hello agent"])

        XCTAssertEqual(
            text,
            "Wall time: 0.0000 seconds\n" +
            "Process exited with code 0\n" +
            "Output:\n" +
            "hello agent\n"
        )
        XCTAssertFalse(text.contains(#""stdout""#))
        XCTAssertFalse(text.contains(#""stderr""#))
        XCTAssertFalse(text.contains(#""exit_code""#))
    }
}
