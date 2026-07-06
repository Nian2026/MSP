import Foundation
import XCTest
import MSPCommandKit
import MSPCore

final class MSPCommandKitTests: XCTestCase {
    func testClosureCommandRunsThroughRegistry() async throws {
        let registry = try MSPCommandRegistry()
        try registry.register("hello") { _, arguments in
            .success(stdout: "hello \(arguments.joined(separator: " "))\n")
        }

        let result = await MSPCommandExecutor(registry: registry).run(
            invocation: MSPCommandInvocation(name: "hello", arguments: ["msp"]),
            context: MSPCommandContext()
        )

        XCTAssertEqual(result, .success(stdout: "hello msp\n"))
    }

    func testExecutorDispatchesStreamingCommandWhenStreamsArePresent() async throws {
        let registry = try MSPCommandRegistry(commands: [CommandKitStreamingProbeCommand()])
        let executor = MSPCommandExecutor(registry: registry)

        let buffered = await executor.run(
            invocation: MSPCommandInvocation(name: "probe", arguments: ["msp"]),
            context: MSPCommandContext()
        )
        XCTAssertEqual(buffered, .success(stdout: "buffered msp\n"))

        let output = CommandKitCollectingOutputStream()
        let streamed = await executor.run(
            invocation: MSPCommandInvocation(name: "probe", arguments: ["msp"]),
            context: MSPCommandContext(standardOutputStream: output)
        )

        let outputText = await output.string()
        XCTAssertEqual(streamed, .success())
        XCTAssertEqual(outputText, "streamed msp\n")
    }

    func testCommandHelpReturnsNilForNonHelpArguments() {
        let help = MSPCommandHelp(
            commandName: "media",
            root: "media root",
            topics: ["show": "media show"]
        )

        XCTAssertNil(help.result(for: ["show", "/图库/a.png"]))
    }

    func testCommandHelpSupportsReadexStyleRootAndTopicForms() {
        let help = MSPCommandHelp(
            commandName: "media",
            root: "media root",
            topics: [
                "show": "media show",
                "show --ocr": "media show --ocr"
            ],
            topicAliases: [
                "show ocr": "show --ocr"
            ]
        )

        XCTAssertEqual(help.result(for: ["--help"]), .success(stdout: "media root\n"))
        XCTAssertEqual(help.result(for: ["help"]), .success(stdout: "media root\n"))
        XCTAssertEqual(help.result(for: ["show", "--help"]), .success(stdout: "media show\n"))
        XCTAssertEqual(help.result(for: ["help", "show"]), .success(stdout: "media show\n"))
        XCTAssertEqual(help.result(for: ["show", "--ocr", "-h"]), .success(stdout: "media show --ocr\n"))
        XCTAssertEqual(help.result(for: ["help", "show", "ocr"]), .success(stdout: "media show --ocr\n"))
    }

    func testCommandHelpReportsUnknownTopicsAsUsageFailures() {
        let help = MSPCommandHelp(
            commandName: "media",
            root: "media root",
            topics: ["show": "media show"]
        )

        let result = help.result(for: ["help", "missing"])

        XCTAssertEqual(result?.exitCode, 2)
        XCTAssertEqual(result?.stdout, "")
        XCTAssertEqual(result?.stderr, "media help: unknown topic missing\n\nmedia root\n")
    }
}

private struct CommandKitStreamingProbeCommand: MSPStreamingCommand {
    let name = "probe"
    let summary: String? = nil

    func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        .success(stdout: "buffered \(invocation.arguments.joined(separator: " "))\n")
    }

    func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        try await context.standardOutputStream?.write(
            Data("streamed \(invocation.arguments.joined(separator: " "))\n".utf8)
        )
        return .success()
    }
}

private final class CommandKitCollectingOutputStream: MSPCommandOutputStream, @unchecked Sendable {
    private let storage = CommandKitCollectingOutputStreamStorage()

    func write(_ data: Data) async throws {
        await storage.write(data)
    }

    func string() async -> String {
        await storage.string()
    }
}

private actor CommandKitCollectingOutputStreamStorage {
    private var collected = Data()

    func write(_ data: Data) {
        collected.append(data)
    }

    func string() -> String {
        String(decoding: collected, as: UTF8.self)
    }
}
