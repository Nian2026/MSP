import Foundation
import MSPCore
import MSPShell

struct ShellBufferedPipelineExecutionContext {
    var initialStandardInput: Data
    var initialStandardInputClosed: Bool
    var runCommand: (
        MSPParsedCommandLine,
        Data,
        Bool,
        Bool,
        MSPRedirectionOutputBinding?,
        MSPRedirectionOutputBinding?
    ) async -> MSPCommandResult
    var updatePipelineStatuses: ([Int32]) -> Void
    var pipelineExitCode: ([Int32]) -> Int32
    var emitVisibleOutput: (MSPCommandResult) async -> MSPCommandResult
}

enum ShellBufferedPipelineExecutor {
    static func run(
        _ pipeline: MSPParsedCommandPipeline,
        context: ShellBufferedPipelineExecutionContext
    ) async -> MSPCommandResult {
        var nextStandardInput = context.initialStandardInput
        var nextStandardInputClosed = context.initialStandardInputClosed
        var shellStderrData = Data()
        var stageExitCodes: [Int32] = []
        var modelContentItems: [MSPCommandModelContentItem] = []

        for index in pipeline.commands.indices {
            let isLast = index == pipeline.commands.count - 1
            let pipeOperator = pipeline.pipeOperators.indices.contains(index)
                ? pipeline.pipeOperators[index]
                : .stdout
            let result = await context.runCommand(
                pipeline.commands[index],
                nextStandardInput,
                nextStandardInputClosed,
                index > 0,
                isLast ? nil : .agentStdout,
                isLast || pipeOperator == .stdout ? nil : .agentStderr
            )
            stageExitCodes.append(result.exitCode)
            modelContentItems.append(contentsOf: result.modelContentItems)

            guard !isLast else {
                context.updatePipelineStatuses(stageExitCodes)
                var stderrData = shellStderrData
                stderrData.append(result.stderrData)
                let result = MSPCommandResult(
                    stdoutData: result.stdoutData,
                    stderrData: stderrData,
                    exitCode: context.pipelineExitCode(stageExitCodes),
                    modelContentItems: modelContentItems
                )
                return await context.emitVisibleOutput(
                    ShellPipelineStatus.result(result, isNegated: pipeline.isNegated)
                )
            }

            switch pipeOperator {
            case .stdout:
                shellStderrData.append(result.stderrData)
                nextStandardInput = result.stdoutData
                nextStandardInputClosed = false
            case .stdoutAndStderr:
                var combined = result.stdoutData
                combined.append(result.stderrData)
                nextStandardInput = combined
                nextStandardInputClosed = false
            }
        }

        context.updatePipelineStatuses([])
        return await context.emitVisibleOutput(
            ShellPipelineStatus.result(.success(), isNegated: pipeline.isNegated)
        )
    }
}
