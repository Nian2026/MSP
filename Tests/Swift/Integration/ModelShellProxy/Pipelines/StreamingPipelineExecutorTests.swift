import Foundation
import XCTest
import MSPCore
import MSPShell
@testable import ModelShellProxy

final class StreamingPipelineExecutorTests: XCTestCase {
    func testFileOutputFlushFailureAdjustsAuditResult() async throws {
        var auditedResults: [MSPCommandResult] = []
        let execution = await ShellStreamingPipelineExecutor.run(
            preparedStages: [
                .command(MSPStreamingPipelineStage(
                    command: StreamingFileOutputCommand(),
                    invocation: MSPCommandInvocation(name: "stream-file", rawInput: "stream-file > out.txt"),
                    parsed: MSPParsedCommandLine(
                        commandName: "stream-file",
                        arguments: [],
                        rawInput: "stream-file > out.txt"
                    ),
                    commandContextSeed: ShellPipelineCommandContextSeed(configuration: MSPConfiguration()),
                    routing: MSPRedirectionRouting(
                        standardInput: Data(),
                        standardInputDescriptor: nil,
                        stdoutBinding: .file(MSPRedirectionFileSink(path: "out.txt", append: false)),
                        stderrBinding: .agentStderr
                    ),
                    usesPipeInput: false,
                    assignments: [],
                    commandSubstitutionStderr: "",
                    expansionState: MSPShellExpansionState(),
                    startedAt: Date(timeIntervalSince1970: 0),
                    processSubstitutionStartIndex: 0
                ))
            ],
            pipeOperators: [],
            context: ShellStreamingPipelineExecutionContext(
                outputStream: nil,
                errorStream: nil,
                fileOutputStream: { _ in nil },
                makeCommandContext: { _, standardInputStream, standardOutputStream, standardErrorStream in
                    MSPCommandContext(
                        standardInputStream: standardInputStream,
                        standardOutputStream: standardOutputStream,
                        standardErrorStream: standardErrorStream
                    )
                },
                emitRedirectionOutput: { _, _, _, _, _ in
                    throw MSPCommandFailure(result: .failure(exitCode: 9, stderr: "stream-file: flush failed\n"))
                },
                finalizeProcessSubstitutions: { _, result in result },
                cleanupProcessSubstitutions: { _ in },
                recordAudit: { _, result, _ in
                    auditedResults.append(result)
                },
                pipelineExitCode: { exitCodes in
                    exitCodes.last ?? 0
                }
            )
        )

        XCTAssertEqual(execution.stageExitCodes, [9])
        XCTAssertEqual(execution.result.stdout, "")
        XCTAssertEqual(execution.result.stderr, "stream-file: flush failed\n")
        XCTAssertEqual(execution.result.exitCode, 9)
        XCTAssertEqual(auditedResults.map(\.exitCode), [9])
        XCTAssertEqual(auditedResults.map(\.stderr), ["stream-file: flush failed\n"])
    }
}

private struct StreamingFileOutputCommand: MSPStreamingCommand {
    var name: String { "stream-file" }
    var summary: String? { nil }

    func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        .success(stdout: "payload")
    }

    func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let standardOutputStream = context.standardOutputStream {
            try await standardOutputStream.write(Data("payload".utf8))
        }
        return .success()
    }
}
