import Foundation
import XCTest
import MSPCore
import MSPShell
@testable import ModelShellProxy

final class PipelineExecutorTests: XCTestCase {
    func testBufferedFacadeForwardsVisibleOutputAndAggregatesModelContent() async throws {
        let output = BufferedPipelineOutputCapture()
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        try shell.register("payload") { _, _ in
            .success(stdout: "abc", modelContentItems: [.inputText("payload-model")])
        }

        let result = await shell.run("payload | wc -c", outputStream: output)

        XCTAssertEqual(result.stdout, "3\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.modelContentItems, [.inputText("payload-model")])
        let visibleOutput = await output.text()
        XCTAssertEqual(visibleOutput, "3\n")
    }

    func testBufferedFacadePipelineInputOverridesPersistentFileDescriptorZero() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)
        try shell.register("emit-pipe") { _, _ in
            .success(stdout: "pipe")
        }
        try shell.register("read-stdin") { context, _ in
            .success(stdoutData: context.standardInput)
        }

        let setup = await shell.run("exec 0<<< persistent")
        let result = await shell.run("emit-pipe | read-stdin")

        XCTAssertEqual(setup.stdout, "")
        XCTAssertEqual(setup.stderr, "")
        XCTAssertEqual(setup.exitCode, 0)
        XCTAssertEqual(result.stdout, "pipe")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testBufferedExecutorRoutesPipeAndStderrAndAggregatesModelContent() async throws {
        var invocations: [BufferedPipelineInvocation] = []
        var updatedStatuses: [Int32] = []
        var visibleResult: MSPCommandResult?

        let result = await ShellBufferedPipelineExecutor.run(
            pipeline(
                commands: [
                    command("left"),
                    command("right")
                ],
                pipeOperators: [.stdoutAndStderr]
            ),
            context: ShellBufferedPipelineExecutionContext(
                initialStandardInput: Data("seed".utf8),
                initialStandardInputClosed: false,
                runCommand: { command, standardInput, standardInputClosed, standardInputOverridesFileDescriptor, stdoutBindingOverride, stderrBindingOverride in
                    invocations.append(BufferedPipelineInvocation(
                        commandName: command.commandName,
                        standardInput: standardInput,
                        standardInputClosed: standardInputClosed,
                        standardInputOverridesFileDescriptor: standardInputOverridesFileDescriptor,
                        stdoutBindingOverride: stdoutBindingOverride,
                        stderrBindingOverride: stderrBindingOverride
                    ))
                    switch command.commandName {
                    case "left":
                        return MSPCommandResult(
                            stdout: "out",
                            stderr: "err",
                            exitCode: 7,
                            modelContentItems: [.inputText("left-model")]
                        )
                    case "right":
                        XCTAssertEqual(String(decoding: standardInput, as: UTF8.self), "outerr")
                        return MSPCommandResult(
                            stdout: "6\n",
                            exitCode: 0,
                            modelContentItems: [.inputText("right-model")]
                        )
                    default:
                        XCTFail("unexpected command \(command.commandName)")
                        return .failure(exitCode: 127, stderr: "unexpected\n")
                    }
                },
                updatePipelineStatuses: { updatedStatuses = $0 },
                pipelineExitCode: { exitCodes in
                    exitCodes.last ?? 0
                },
                emitVisibleOutput: { output in
                    visibleResult = output
                    return output
                }
            )
        )

        XCTAssertEqual(result.stdout, "6\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.modelContentItems, [.inputText("left-model"), .inputText("right-model")])
        XCTAssertEqual(updatedStatuses, [7, 0])
        XCTAssertEqual(visibleResult, result)
        XCTAssertEqual(invocations, [
            BufferedPipelineInvocation(
                commandName: "left",
                standardInput: Data("seed".utf8),
                standardInputClosed: false,
                standardInputOverridesFileDescriptor: false,
                stdoutBindingOverride: .agentStdout,
                stderrBindingOverride: .agentStderr
            ),
            BufferedPipelineInvocation(
                commandName: "right",
                standardInput: Data("outerr".utf8),
                standardInputClosed: false,
                standardInputOverridesFileDescriptor: true,
                stdoutBindingOverride: nil,
                stderrBindingOverride: nil
            )
        ])
    }

    func testBufferedExecutorPreservesIntermediateStderrAndPipefailExit() async throws {
        let result = await ShellBufferedPipelineExecutor.run(
            pipeline(
                commands: [
                    command("left"),
                    command("right")
                ],
                pipeOperators: [.stdout]
            ),
            context: ShellBufferedPipelineExecutionContext(
                initialStandardInput: Data(),
                initialStandardInputClosed: false,
                runCommand: { command, standardInput, _, _, stdoutBindingOverride, stderrBindingOverride in
                    switch command.commandName {
                    case "left":
                        XCTAssertEqual(standardInput, Data())
                        XCTAssertEqual(stdoutBindingOverride, .agentStdout)
                        XCTAssertEqual(stderrBindingOverride, nil)
                        return MSPCommandResult(stdout: "out", stderr: "err", exitCode: 7)
                    case "right":
                        XCTAssertEqual(String(decoding: standardInput, as: UTF8.self), "out")
                        XCTAssertEqual(stdoutBindingOverride, nil)
                        XCTAssertEqual(stderrBindingOverride, nil)
                        return MSPCommandResult(stdout: "3\n", exitCode: 0)
                    default:
                        XCTFail("unexpected command \(command.commandName)")
                        return .failure(exitCode: 127, stderr: "unexpected\n")
                    }
                },
                updatePipelineStatuses: { XCTAssertEqual($0, [7, 0]) },
                pipelineExitCode: { exitCodes in
                    exitCodes.first { $0 != 0 } ?? 0
                },
                emitVisibleOutput: { $0 }
            )
        )

        XCTAssertEqual(result.stdout, "3\n")
        XCTAssertEqual(result.stderr, "err")
        XCTAssertEqual(result.exitCode, 7)
    }

    func testBufferedExecutorAppliesPipelineNegation() async throws {
        let result = await ShellBufferedPipelineExecutor.run(
            pipeline(
                commands: [
                    command("false")
                ],
                pipeOperators: [],
                isNegated: true
            ),
            context: ShellBufferedPipelineExecutionContext(
                initialStandardInput: Data(),
                initialStandardInputClosed: false,
                runCommand: { _, _, _, _, _, _ in
                    MSPCommandResult(exitCode: 7)
                },
                updatePipelineStatuses: { XCTAssertEqual($0, [7]) },
                pipelineExitCode: { exitCodes in
                    exitCodes.last ?? 0
                },
                emitVisibleOutput: { $0 }
            )
        )

        XCTAssertEqual(result.exitCode, 0)
    }

    private func command(_ name: String) -> MSPParsedCommandLine {
        MSPParsedCommandLine(commandName: name, arguments: [], rawInput: name)
    }

    private func pipeline(
        commands: [MSPParsedCommandLine],
        pipeOperators: [MSPParsedPipeOperator],
        isNegated: Bool = false
    ) -> MSPParsedCommandPipeline {
        MSPParsedCommandPipeline(
            isNegated: isNegated,
            commands: commands,
            pipeOperators: pipeOperators,
            rawInput: commands.map(\.rawInput).joined(separator: " | ")
        )
    }
}

private struct BufferedPipelineInvocation: Equatable {
    var commandName: String
    var standardInput: Data
    var standardInputClosed: Bool
    var standardInputOverridesFileDescriptor: Bool
    var stdoutBindingOverride: MSPRedirectionOutputBinding?
    var stderrBindingOverride: MSPRedirectionOutputBinding?
}

private actor BufferedPipelineOutputCapture: MSPCommandOutputStream {
    private var buffer = Data()

    func write(_ data: Data) async throws {
        buffer.append(data)
    }

    func closeWrite() async {}

    func text() -> String {
        String(decoding: buffer, as: UTF8.self)
    }
}
