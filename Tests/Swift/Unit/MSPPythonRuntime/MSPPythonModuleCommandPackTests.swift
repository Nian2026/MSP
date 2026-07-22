import Foundation
import XCTest
import MSPCore
@testable import MSPPythonRuntime

final class MSPPythonModuleCommandPackTests: XCTestCase {
    func testRegistersModuleCommandAndProjectsInvocation() async throws {
        let runtime = ModuleCommandRecordingPythonRuntime()
        let registry = try MSPCommandRegistry()
        let pack = MSPPythonModuleCommandPack(
            commandName: "module-tool",
            moduleName: "example.tool",
            runtime: runtime,
            summary: "Example Python module tool",
            commandLookupPaths: ["/usr/local/bin/module-tool"]
        )

        try pack.registerCommands(into: registry)

        XCTAssertEqual(pack.name, "python-module-module-tool")
        XCTAssertEqual(registry.command(named: "module-tool")?.summary, "Example Python module tool")
        XCTAssertEqual(
            registry.commandLookupPaths["module-tool"],
            ["/usr/local/bin/module-tool"]
        )

        let result = await MSPCommandExecutor(registry: registry).run(
            invocation: MSPCommandInvocation(
                name: "module-tool",
                arguments: ["--flag", "value"],
                rawInput: "module-tool --flag value"
            ),
            context: MSPCommandContext(
                currentDirectory: "/workspace",
                standardInput: Data("input".utf8)
            )
        )

        XCTAssertEqual(result, .success(stdout: "buffered\n"))
        let request = await runtime.bufferedRequest
        XCTAssertEqual(
            request,
            MSPPythonExecutionRequest(
                invocation: MSPPythonInvocation(
                    commandName: "module-tool",
                    arguments: ["--flag", "value"],
                    rawInput: "module-tool --flag value"
                ),
                entrypoint: .module(
                    name: "example.tool",
                    arguments: ["--flag", "value"]
                ),
                virtualCurrentDirectory: "/workspace"
            )
        )
    }

    func testDispatchesStreamingExecutionToPythonRuntime() async throws {
        let runtime = ModuleCommandRecordingPythonRuntime()
        let registry = try MSPCommandRegistry()
        try MSPPythonModuleCommandPack(
            commandName: "module-tool",
            moduleName: "example.tool",
            runtime: runtime
        ).registerCommands(into: registry)

        let result = await MSPCommandExecutor(registry: registry).run(
            invocation: MSPCommandInvocation(name: "module-tool", arguments: ["--stream"]),
            context: MSPCommandContext(standardOutputStream: MSPCommandOutputBuffer())
        )

        XCTAssertEqual(result, .success(stdout: "streaming\n"))
        let request = await runtime.streamingRequest
        XCTAssertEqual(
            request?.entrypoint,
            .module(name: "example.tool", arguments: ["--stream"])
        )
    }
}

private actor ModuleCommandRecordingPythonRuntime: MSPPythonRuntime {
    private(set) var bufferedRequest: MSPPythonExecutionRequest?
    private(set) var streamingRequest: MSPPythonExecutionRequest?

    func runPython(
        request: MSPPythonExecutionRequest,
        context: MSPCommandContext
    ) async -> MSPCommandResult {
        bufferedRequest = request
        return .success(stdout: "buffered\n")
    }

    func runPythonStreaming(
        request: MSPPythonExecutionRequest,
        context: MSPCommandContext
    ) async -> MSPCommandResult {
        streamingRequest = request
        return .success(stdout: "streaming\n")
    }
}
