import Foundation
import MSPCore
import MSPShell

struct MSPStreamingPipelineExecution {
    var result: MSPCommandResult
    var stageExitCodes: [Int32]
}

struct ShellStreamingPipelineExecutionContext {
    var outputStream: (any MSPCommandOutputStream)?
    var errorStream: (any MSPCommandOutputStream)?
    var fileOutputStream: (MSPRedirectionFileSink) -> (any MSPCommandOutputStream)?
    var makeCommandContext: (
        MSPStreamingPipelineStage,
        any MSPCommandInputStream,
        any MSPCommandOutputStream,
        any MSPCommandOutputStream
    ) -> MSPCommandContext
    var emitRedirectionOutput: (
        Data,
        MSPRedirectionOutputBinding,
        inout Data,
        inout Data,
        inout Set<String>
    ) throws -> Void
    var finalizeProcessSubstitutions: (Int, MSPCommandResult) async throws -> MSPCommandResult
    var cleanupProcessSubstitutions: (Int) -> Void
    var recordAudit: (MSPParsedCommandLine, MSPCommandResult, Date) async -> Void
    var pipelineExitCode: ([Int32]) -> Int32
}

enum ShellStreamingPipelineExecutor {
    static func run(
        preparedStages: [MSPStreamingPipelinePreparedStage],
        pipeOperators: [MSPParsedPipeOperator],
        context: ShellStreamingPipelineExecutionContext
    ) async -> MSPStreamingPipelineExecution {
        let finalStdoutBuffer = MSPCommandOutputBuffer()
        let finalStderrBuffer = MSPCommandOutputBuffer()
        let finalStdout: any MSPCommandOutputStream = context.outputStream.map {
            MSPTeeOutputStream([finalStdoutBuffer, $0])
        } ?? finalStdoutBuffer
        let finalStderr: any MSPCommandOutputStream = context.errorStream.map {
            MSPTeeOutputStream([finalStderrBuffer, $0])
        } ?? finalStderrBuffer
        let pipes = (0..<max(0, preparedStages.count - 1)).map { _ in
            MSPStreamingPipelinePipe(maxBufferedChunks: 32)
        }
        var runnableStages: [MSPStreamingPipelineRunnableStage] = []
        var runnableResultStages: [MSPStreamingPipelineRunnableResultStage] = []
        for index in preparedStages.indices {
            let isLast = index == preparedStages.count - 1
            let defaultStdout: any MSPCommandOutputStream = isLast ? finalStdout : pipes[index]
            let pipeOperator = pipeOperators.indices.contains(index)
                ? pipeOperators[index]
                : .stdout
            let defaultStderr: any MSPCommandOutputStream = (!isLast && pipeOperator == .stdoutAndStderr)
                ? pipes[index]
                : finalStderr
            switch preparedStages[index] {
            case .command(let stage):
                let standardInputStream = Self.standardInputStream(
                    for: stage,
                    pipeInput: stage.usesPipeInput ? pipes[index - 1] : nil
                )
                var fileOutputs: [MSPStreamingPipelineFileOutput] = []
                let stdoutStream = ShellPipelineStreams.makeOutputStream(
                    for: stage.routing.stdoutBinding,
                    defaultStdout: defaultStdout,
                    defaultStderr: defaultStderr,
                    closedReason: "standard output: Bad file descriptor",
                    fileOutputs: &fileOutputs,
                    fileOutputStream: context.fileOutputStream
                )
                let stderrStream = ShellPipelineStreams.makeOutputStream(
                    for: stage.routing.stderrBinding,
                    defaultStdout: defaultStdout,
                    defaultStderr: defaultStderr,
                    closedReason: "standard error: Bad file descriptor",
                    fileOutputs: &fileOutputs,
                    fileOutputStream: context.fileOutputStream
                )
                runnableStages.append(MSPStreamingPipelineRunnableStage(
                    index: index,
                    command: stage.command,
                    invocation: stage.invocation,
                    context: context.makeCommandContext(
                        stage,
                        standardInputStream,
                        stdoutStream,
                        stderrStream
                    ),
                    standardInputStream: standardInputStream,
                    standardOutputStream: stdoutStream,
                    standardErrorStream: stderrStream,
                    pipeOutput: isLast ? nil : pipes[index],
                    fileOutputs: fileOutputs,
                    commandSubstitutionStderr: stage.commandSubstitutionStderr,
                    parsed: stage.parsed,
                    startedAt: stage.startedAt,
                    processSubstitutionStartIndex: stage.processSubstitutionStartIndex
                ))
            case .result(let stage):
                runnableResultStages.append(MSPStreamingPipelineRunnableResultStage(
                    index: index,
                    result: stage.result,
                    pipeInput: index > 0 ? pipes[index - 1] : nil,
                    standardOutputStream: defaultStdout,
                    standardErrorStream: defaultStderr,
                    pipeOutput: isLast ? nil : pipes[index],
                    parsed: stage.parsed,
                    startedAt: stage.startedAt
                ))
            }
        }

        var completions = Array<MSPStreamingPipelineStageCompletion?>(repeating: nil, count: preparedStages.count)
        await withTaskGroup(of: MSPStreamingPipelineStageCompletion.self) { group in
            for runnable in runnableStages {
                group.addTask {
                    await ShellPipelineStageRunner.run(runnable)
                }
            }
            for runnable in runnableResultStages {
                group.addTask {
                    await Self.runResultStage(runnable)
                }
            }
            for await completion in group {
                completions[completion.index] = completion
            }
        }

        var stageExitCodes: [Int32] = []
        var redirectionVisibleStdout = Data()
        var redirectionVisibleStderr = Data()
        var writtenFilePaths = Set<String>()
        var modelContentItems: [MSPCommandModelContentItem] = []
        var singleStageStateChange: MSPCommandRuntimeStateChange?
        for completion in completions.compactMap({ $0 }).sorted(by: { $0.index < $1.index }) {
            stageExitCodes.append(completion.result.exitCode)
            modelContentItems.append(contentsOf: completion.result.modelContentItems)
            var auditedResult = completion.result
            for fileOutput in completion.fileOutputs {
                do {
                    try context.emitRedirectionOutput(
                        await fileOutput.buffer.data(),
                        fileOutput.binding,
                        &redirectionVisibleStdout,
                        &redirectionVisibleStderr,
                        &writtenFilePaths
                    )
                } catch let failure as MSPCommandFailure {
                    stageExitCodes[stageExitCodes.count - 1] = failure.result.exitCode
                    redirectionVisibleStderr.append(failure.result.stderrData)
                    auditedResult.exitCode = failure.result.exitCode
                    auditedResult.stderrData.append(failure.result.stderrData)
                } catch {
                    let stderr = Data("\(completion.parsed.commandName): \(error)\n".utf8)
                    stageExitCodes[stageExitCodes.count - 1] = 1
                    redirectionVisibleStderr.append(stderr)
                    auditedResult.exitCode = 1
                    auditedResult.stderrData.append(stderr)
                }
            }
            if preparedStages.count == 1, auditedResult.succeeded {
                singleStageStateChange = auditedResult.stateChange
            }
            if let processSubstitutionStartIndex = completion.processSubstitutionStartIndex {
                do {
                    let stdoutCount = auditedResult.stdoutData.count
                    let stderrCount = auditedResult.stderrData.count
                    let modelContentCount = auditedResult.modelContentItems.count
                    let finalizedResult = try await context.finalizeProcessSubstitutions(
                        processSubstitutionStartIndex,
                        auditedResult
                    )
                    if finalizedResult.exitCode != auditedResult.exitCode {
                        stageExitCodes[stageExitCodes.count - 1] = finalizedResult.exitCode
                    }
                    redirectionVisibleStdout.append(finalizedResult.stdoutData.dropFirst(stdoutCount))
                    redirectionVisibleStderr.append(finalizedResult.stderrData.dropFirst(stderrCount))
                    modelContentItems.append(contentsOf: finalizedResult.modelContentItems.dropFirst(modelContentCount))
                    auditedResult = finalizedResult
                } catch let failure as MSPCommandFailure {
                    stageExitCodes[stageExitCodes.count - 1] = failure.result.exitCode
                    redirectionVisibleStderr.append(failure.result.stderrData)
                    auditedResult.exitCode = failure.result.exitCode
                    auditedResult.stderrData.append(failure.result.stderrData)
                } catch {
                    let stderr = Data("\(completion.parsed.commandName): \(error)\n".utf8)
                    stageExitCodes[stageExitCodes.count - 1] = 1
                    redirectionVisibleStderr.append(stderr)
                    auditedResult.exitCode = 1
                    auditedResult.stderrData.append(stderr)
                }
                context.cleanupProcessSubstitutions(processSubstitutionStartIndex)
            }
            await context.recordAudit(
                completion.parsed,
                auditedResult,
                completion.startedAt
            )
        }

        var stdoutData = await finalStdoutBuffer.data()
        stdoutData.append(redirectionVisibleStdout)
        if !redirectionVisibleStdout.isEmpty {
            try? await context.outputStream?.write(redirectionVisibleStdout)
        }
        var stderrData = await finalStderrBuffer.data()
        stderrData.append(redirectionVisibleStderr)
        if !redirectionVisibleStderr.isEmpty {
            try? await context.errorStream?.write(redirectionVisibleStderr)
        }
        return MSPStreamingPipelineExecution(
            result: MSPCommandResult(
                stdoutData: stdoutData,
                stderrData: stderrData,
                exitCode: context.pipelineExitCode(stageExitCodes),
                stateChange: singleStageStateChange,
                modelContentItems: modelContentItems
            ),
            stageExitCodes: stageExitCodes
        )
    }

    private static func standardInputStream(
        for stage: MSPStreamingPipelineStage,
        pipeInput: MSPStreamingPipelinePipe?
    ) -> any MSPCommandInputStream {
        if let pipeInput {
            return pipeInput
        }
        if IORuntimeState.redirectionsScopeStandardInput(stage.parsed.redirections) {
            if stage.routing.standardInputClosed {
                return ShellClosedInputStream(reason: "stdin: Bad file descriptor")
            }
            return MSPDataInputStream(stage.routing.standardInput)
        }
        return stage.commandContextSeed.standardInputStream
            ?? MSPDataInputStream(stage.routing.standardInput)
    }

    private static func runResultStage(
        _ stage: MSPStreamingPipelineRunnableResultStage
    ) async -> MSPStreamingPipelineStageCompletion {
        var completionResult = stage.result
        await stage.pipeInput?.closeRead()
        if !stage.result.stdoutData.isEmpty {
            do {
                try await stage.standardOutputStream.write(stage.result.stdoutData)
            } catch MSPCommandStreamError.brokenPipe {
                if stage.pipeOutput != nil, completionResult.exitCode == 0 {
                    completionResult.exitCode = ShellPipelineStreams.brokenPipeExitCode
                }
            } catch MSPCommandStreamError.writeError(let reason) {
                completionResult = .failure(exitCode: 1, stderr: "\(stage.parsed.commandName): \(reason)\n")
            } catch {
                completionResult = .failure(exitCode: 1, stderr: "\(stage.parsed.commandName): \(error)\n")
            }
        }
        if !stage.result.stderrData.isEmpty {
            try? await stage.standardErrorStream.write(stage.result.stderrData)
        }
        if let pipeOutput = stage.pipeOutput,
           await pipeOutput.didBreakOnWrite,
           completionResult.exitCode == 0 {
            completionResult.exitCode = ShellPipelineStreams.brokenPipeExitCode
        }
        await stage.standardOutputStream.closeWrite()
        await stage.standardErrorStream.closeWrite()
        return MSPStreamingPipelineStageCompletion(
            index: stage.index,
            result: completionResult,
            fileOutputs: [],
            parsed: stage.parsed,
            startedAt: stage.startedAt,
            processSubstitutionStartIndex: nil
        )
    }
}

private final class ShellClosedInputStream: MSPCommandInputStream {
    private let reason: String

    init(reason: String) {
        self.reason = reason
    }

    func read(maxBytes: Int) async throws -> Data? {
        throw MSPCommandStreamError.writeError(reason)
    }
}
