import Foundation
import XCTest
import MSPCore
import MSPShell
@testable import ModelShellProxy

final class PipelineStageRunnerTests: XCTestCase {
    func testBrokenPipeThrownByStreamingCommandMapsOnlyNonFinalStagesToSigpipe() async throws {
        let nonFinalPipe = MSPStreamingPipelinePipe()
        let nonFinalStderr = MSPCommandOutputBuffer()
        let finalStderr = MSPCommandOutputBuffer()

        let nonFinal = await ShellPipelineStageRunner.run(
            runnableStage(
                command: BrokenPipeThrowingStreamingCommand(),
                standardOutputStream: nonFinalPipe,
                standardErrorStream: nonFinalStderr,
                pipeOutput: nonFinalPipe,
                commandSubstitutionStderr: "pre\n"
            )
        )
        let final = await ShellPipelineStageRunner.run(
            runnableStage(
                command: BrokenPipeThrowingStreamingCommand(),
                standardErrorStream: finalStderr,
                pipeOutput: nil,
                commandSubstitutionStderr: "pre\n"
            )
        )

        XCTAssertEqual(nonFinal.result.exitCode, ShellPipelineStreams.brokenPipeExitCode)
        XCTAssertEqual(nonFinal.result.stderr, "")
        XCTAssertEqual(final.result.exitCode, 0)
        XCTAssertEqual(final.result.stderr, "")
        let nonFinalStderrText = String(data: await nonFinalStderr.data(), encoding: .utf8)
        let finalStderrText = String(data: await finalStderr.data(), encoding: .utf8)
        XCTAssertEqual(nonFinalStderrText, "pre\n")
        XCTAssertEqual(finalStderrText, "pre\n")
    }

    func testBufferedStdoutFlushBrokenPipeMapsSuccessfulNonFinalStageToSigpipe() async throws {
        let pipe = MSPStreamingPipelinePipe()
        await pipe.closeRead()

        let completion = await ShellPipelineStageRunner.run(
            runnableStage(
                command: BufferedStdoutStreamingCommand(),
                standardOutputStream: pipe,
                pipeOutput: pipe
            )
        )

        XCTAssertEqual(completion.result.exitCode, ShellPipelineStreams.brokenPipeExitCode)
        XCTAssertEqual(completion.result.stdoutData, Data())
        let didBreakOnWrite = await pipe.didBreakOnWrite
        XCTAssertEqual(didBreakOnWrite, true)
    }

    private func runnableStage(
        command: any MSPStreamingCommand,
        standardOutputStream: any MSPCommandOutputStream = MSPCommandOutputBuffer(),
        standardErrorStream: any MSPCommandOutputStream = MSPCommandOutputBuffer(),
        pipeOutput: MSPStreamingPipelinePipe?,
        commandSubstitutionStderr: String = ""
    ) -> MSPStreamingPipelineRunnableStage {
        MSPStreamingPipelineRunnableStage(
            index: 0,
            command: command,
            invocation: MSPCommandInvocation(name: command.name, rawInput: command.name),
            context: MSPCommandContext(),
            standardInputStream: MSPDataInputStream(Data()),
            standardOutputStream: standardOutputStream,
            standardErrorStream: standardErrorStream,
            pipeOutput: pipeOutput,
            fileOutputs: [],
            commandSubstitutionStderr: commandSubstitutionStderr,
            parsed: MSPParsedCommandLine(
                commandName: command.name,
                arguments: [],
                rawInput: command.name
            ),
            startedAt: Date(timeIntervalSince1970: 0),
            processSubstitutionStartIndex: 0
        )
    }
}

private struct BrokenPipeThrowingStreamingCommand: MSPStreamingCommand {
    var name: String { "broken-pipe-thrower" }
    var summary: String? { nil }

    func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        .success()
    }

    func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        throw MSPCommandStreamError.brokenPipe
    }
}

private struct BufferedStdoutStreamingCommand: MSPStreamingCommand {
    var name: String { "buffered-stdout" }
    var summary: String? { nil }

    func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        .success(stdout: "late\n")
    }

    func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        .success(stdout: "late\n")
    }
}
