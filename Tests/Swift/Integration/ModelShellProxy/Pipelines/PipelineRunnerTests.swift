import Foundation
import XCTest
import MSPApple
import MSPCore
import MSPShell
@testable import ModelShellProxy

final class PipelineRunnerTests: ModelShellProxyIntegrationTestCase {
    func testObservedSingleStreamingCommandAppliesExpansionAndStateChange() async throws {
        let output = PipelineRunnerOutputCapture()
        let registry = try MSPCommandRegistry(commands: [
            RunnerStatefulStreamingCommand()
        ])
        let shell = try ModelShellProxy(registry: registry)
            .enable(.posixCore)

        let observed = await shell.run("runner-state ${x:=kept}", outputStream: output)
        let state = await shell.run(#"printf '%s:%s\n' "$x" "$PWD""#)

        XCTAssertEqual(observed.stdout, "visible\n")
        XCTAssertEqual(observed.stderr, "")
        XCTAssertEqual(observed.exitCode, 0)
        let observedOutput = await output.text()
        XCTAssertEqual(observedOutput, "visible\n")
        XCTAssertEqual(state.stdout, "kept:/changed\n")
        XCTAssertEqual(state.stderr, "")
        XCTAssertEqual(state.exitCode, 0)
    }

    func testStreamingPipelineInheritsPersistentStdoutOnlyForFinalStage() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let result = await shell.run("""
        exec 3>&1 > out.txt
        yes ok | head -n 1
        exec >&3 3>&-
        printf 'file='
        cat out.txt
        """)

        XCTAssertEqual(result.stdout, "file=ok\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testStreamingPipelineInheritsPersistentStderrUnlessPipeAndStderrIsRequested() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let registry = try MSPCommandRegistry(commands: [
            RunnerBothStreamingCommand()
        ])
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let shell = try ModelShellProxy(
            configuration: MSPConfiguration(workspace: workspace),
            registry: registry
        )
            .enable(.posixCore)

        let ordinaryPipe = await shell.run("""
        exec 3>&2 2> err.txt
        runner-both | wc -c
        exec 2>&3 3>&-
        printf 'err='
        cat err.txt
        """)
        let stderrPipe = await shell.run("runner-both |& wc -c")

        XCTAssertEqual(ordinaryPipe.stdout, "4\nerr=err\n")
        XCTAssertEqual(ordinaryPipe.stderr, "")
        XCTAssertEqual(ordinaryPipe.exitCode, 0)
        XCTAssertEqual(stderrPipe.stdout, "8\n")
        XCTAssertEqual(stderrPipe.stderr, "")
        XCTAssertEqual(stderrPipe.exitCode, 0)
    }

    func testStreamingPipelineNegationLeavesPipeStatusesUnnegated() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let pipefail = await shell.run("""
        set -o pipefail
        ! yes ok | head -n 1
        printf 'neg=%s/%s:%s\\n' "${PIPESTATUS[0]}" "${PIPESTATUS[1]}" "$?"
        """)
        let plain = await shell.run("""
        set +o pipefail
        ! yes ok | head -n 1
        printf 'plain=%s/%s:%s\\n' "${PIPESTATUS[0]}" "${PIPESTATUS[1]}" "$?"
        """)

        XCTAssertEqual(pipefail.stdout, "ok\nneg=141/0:0\n")
        XCTAssertEqual(pipefail.stderr, "")
        XCTAssertEqual(pipefail.exitCode, 0)
        XCTAssertEqual(plain.stdout, "ok\nplain=141/0:1\n")
        XCTAssertEqual(plain.stderr, "")
        XCTAssertEqual(plain.exitCode, 0)
    }

    func testStreamingPipelineAcceptsVirtualAbsoluteCommandPaths() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let result = await shell.run("""
        set -o pipefail
        /usr/bin/yes ok | /bin/head -n 1
        printf 'status=%s/%s:%s\\n' "${PIPESTATUS[0]}" "${PIPESTATUS[1]}" "$?"
        """)

        XCTAssertEqual(result.stdout, "ok\nstatus=141/0:141\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testStreamingStageContextAppliesAssignmentEnvironment() async throws {
        let registry = try MSPCommandRegistry(commands: [
            RunnerEnvironmentStreamingCommand()
        ])
        let shell = try ModelShellProxy(registry: registry)
            .enable(.posixCore)

        let result = await shell.run("MARK=stage-value runner-env | cat")

        XCTAssertEqual(result.stdout, "stage-value\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }
}

private struct RunnerStatefulStreamingCommand: MSPStreamingCommand {
    var name: String { "runner-state" }
    var summary: String? { nil }

    func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        .success(stdout: "visible\n", stateChange: MSPCommandRuntimeStateChange(currentDirectory: "/changed"))
    }

    func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let stdout = context.standardOutputStream {
            try await stdout.write(Data("visible\n".utf8))
        }
        return .success(stateChange: MSPCommandRuntimeStateChange(currentDirectory: "/changed"))
    }
}

private struct RunnerBothStreamingCommand: MSPStreamingCommand {
    var name: String { "runner-both" }
    var summary: String? { nil }

    func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        MSPCommandResult(stdout: "out\n", stderr: "err\n")
    }

    func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let stdout = context.standardOutputStream {
            try await stdout.write(Data("out\n".utf8))
        }
        if let stderr = context.standardErrorStream {
            try await stderr.write(Data("err\n".utf8))
        }
        return .success()
    }
}

private struct RunnerEnvironmentStreamingCommand: MSPStreamingCommand {
    var name: String { "runner-env" }
    var summary: String? { nil }

    func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        .success(stdout: "\(context.environment["MARK"] ?? "")\n")
    }

    func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let stdout = context.standardOutputStream {
            try await stdout.write(Data("\(context.environment["MARK"] ?? "")\n".utf8))
        }
        return .success()
    }
}

private actor PipelineRunnerOutputCapture: MSPCommandOutputStream {
    private var buffer = Data()

    func write(_ data: Data) async throws {
        buffer.append(data)
    }

    func closeWrite() async {}

    func text() -> String {
        String(decoding: buffer, as: UTF8.self)
    }
}
