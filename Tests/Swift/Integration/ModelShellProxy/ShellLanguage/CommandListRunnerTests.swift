import XCTest
@testable import ModelShellProxy
import MSPShell

final class CommandListRunnerTests: ModelShellProxyIntegrationTestCase {
    func testCommandListRunnerShortCircuitsAndAggregatesOutput() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let result = await shell.run("false && echo no; echo after; false || echo fallback")

        XCTAssertEqual(result.stdout, "after\nfallback\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testCommandListRunnerRunsExitTrapAfterErrexitStop() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let result = await shell.run("trap 'echo cleanup' EXIT; set -e; false; echo never")

        XCTAssertEqual(result.stdout, "cleanup\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 1)
    }

    func testParsedCommandListRuntimeEntryPreservesOptionsAndStreams() async throws {
        let shell = try ModelShellProxy(
            configuration: MSPConfiguration(shellDiagnosticProfile: .bash(scriptName: "parsed.sh"))
        )
        .enable(.posixCore)
        let commandLine = """
        echo initial:$?
        set -e
        false
        echo survived
        missing_direct
        """
        let commandList = MSPParsedCommandList(
            pipelines: try MSPShellParser().parseExecutablePipelines(commandLine),
            rawInput: commandLine
        )
        let stdoutStream = MSPCommandOutputBuffer()
        let stderrStream = MSPCommandOutputBuffer()

        let result = await shell.run(
            commandList,
            initialLastExitCode: 42,
            clearsShellControlAtEnd: true,
            suppressesErrexit: true,
            sourceLineOffset: 10,
            outputStream: stdoutStream,
            errorStream: stderrStream
        )

        XCTAssertEqual(result.stdout, "initial:42\nsurvived\n")
        XCTAssertEqual(result.stderr, "parsed.sh: line 15: missing_direct: command not found\n")
        XCTAssertEqual(result.exitCode, 127)
        let streamedStdout = String(data: await stdoutStream.data(), encoding: .utf8)
        let streamedStderr = String(data: await stderrStream.data(), encoding: .utf8)
        XCTAssertEqual(streamedStdout, result.stdout)
        XCTAssertEqual(streamedStderr, result.stderr)
    }

    func testRuntimeCommandListPortsAggregatePipelineTrapResultAndVisibleStreams() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
            .register("trap-payload") { _, _ in
                .success(
                    stdout: "trap-out\n",
                    stderr: "trap-err\n",
                    modelContentItems: [MSPCommandModelContentItem.inputText("trap-model")]
                )
            }
        let stdoutStream = MSPCommandOutputBuffer()
        let stderrStream = MSPCommandOutputBuffer()

        let result = await shell.run(
            "echo before; trap 'trap-payload' EXIT; set -e; false; echo never",
            outputStream: stdoutStream,
            errorStream: stderrStream
        )

        XCTAssertEqual(result.stdout, "before\ntrap-out\n")
        XCTAssertEqual(result.stderr, "trap-err\n")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(result.modelContentItems, [MSPCommandModelContentItem.inputText("trap-model")])
        let streamedStdout = String(data: await stdoutStream.data(), encoding: .utf8)
        let streamedStderr = String(data: await stderrStream.data(), encoding: .utf8)
        XCTAssertEqual(streamedStdout, "before\n")
        XCTAssertEqual(streamedStderr, "")
    }
}
