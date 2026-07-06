import Foundation
import MSPCore
import MSPShell

struct ShellPipelineCommandExecutionRequest {
    var fullCommandLine: String
    var standardInput: Data
    var standardInputClosed: Bool
    var standardInputOverridesFileDescriptor: Bool
    var stdoutBindingOverride: MSPRedirectionOutputBinding?
    var stderrBindingOverride: MSPRedirectionOutputBinding?
    var appliesStateChange: Bool
    var lastExitCode: Int32
    var sourceLineNumber: Int?
    var outputStream: (any MSPCommandOutputStream)?
    var errorStream: (any MSPCommandOutputStream)?
}

struct ShellPipelineRunnerContext {
    var fullCommandLine: String
    var lastExitCode: Int32
    var sourceLineNumber: Int?
    var initialStandardInput: Data
    var initialStandardInputClosed: Bool
    var outputStream: (any MSPCommandOutputStream)?
    var errorStream: (any MSPCommandOutputStream)?

    var runCommand: (MSPParsedCommandLine, ShellPipelineCommandExecutionRequest) async -> MSPCommandResult
    var streamingCommand: @Sendable (String) -> (any MSPStreamingCommand)?
    var shellFunctionExists: @Sendable (String) -> Bool
    var resolveVirtualExecutableCommandPath: @Sendable (String) -> String?
    var makeStagePreparationContext: () -> ShellPipelineStagePreparationContext

    var fileOutputStream: (MSPRedirectionFileSink) -> (any MSPCommandOutputStream)?
    var makeStreamingCommandContext: (
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

    var applyExpansionState: (MSPShellExpansionState) -> Void
    var applyCommandStateChange: (MSPCommandRuntimeStateChange?) -> Void
    var updatePipelineStatuses: ([Int32]) -> Void
    var pipelineExitCode: ([Int32]) -> Int32
    var emitStreamProbe: (String, [String: String]) -> Void
}

enum ShellPipelineRunner {
    static func run(
        _ pipeline: MSPParsedCommandPipeline,
        context: ShellPipelineRunnerContext
    ) async -> MSPCommandResult {
        guard !pipeline.commands.isEmpty else {
            return pipelineResult(.success(), pipeline: pipeline)
        }
        if pipeline.commands.count > 1 || context.outputStream != nil || context.errorStream != nil,
           let streamingResult = await runStreamingPipelineIfEligible(
            pipeline,
            context: context
           ) {
            return pipelineResult(streamingResult, pipeline: pipeline)
        }

        guard pipeline.commands.count > 1 else {
            let command = pipeline.commands[0]
            let streamsOutputInternally = singleCommandStreamsOutputInternally(
                command,
                shellFunctionExists: context.shellFunctionExists
            )
            let result = await context.runCommand(
                command,
                ShellPipelineCommandExecutionRequest(
                    fullCommandLine: context.fullCommandLine,
                    standardInput: context.initialStandardInput,
                    standardInputClosed: context.initialStandardInputClosed,
                    standardInputOverridesFileDescriptor: false,
                    stdoutBindingOverride: nil,
                    stderrBindingOverride: nil,
                    appliesStateChange: true,
                    lastExitCode: context.lastExitCode,
                    sourceLineNumber: context.sourceLineNumber,
                    outputStream: streamsOutputInternally ? context.outputStream : nil,
                    errorStream: streamsOutputInternally ? context.errorStream : nil
                )
            )
            context.updatePipelineStatuses([result.exitCode])
            let pipelineResult = pipelineResult(result, pipeline: pipeline)
            guard !streamsOutputInternally else {
                return pipelineResult
            }
            return await emitVisiblePipelineOutput(pipelineResult, context: context)
        }

        return await ShellBufferedPipelineExecutor.run(
            pipeline,
            context: ShellBufferedPipelineExecutionContext(
                initialStandardInput: context.initialStandardInput,
                initialStandardInputClosed: context.initialStandardInputClosed,
                runCommand: { command, standardInput, standardInputClosed, standardInputOverridesFileDescriptor, stdoutBindingOverride, stderrBindingOverride in
                    await context.runCommand(
                        command,
                        ShellPipelineCommandExecutionRequest(
                            fullCommandLine: context.fullCommandLine,
                            standardInput: standardInput,
                            standardInputClosed: standardInputClosed,
                            standardInputOverridesFileDescriptor: standardInputOverridesFileDescriptor,
                            stdoutBindingOverride: stdoutBindingOverride,
                            stderrBindingOverride: stderrBindingOverride,
                            appliesStateChange: false,
                            lastExitCode: context.lastExitCode,
                            sourceLineNumber: context.sourceLineNumber,
                            outputStream: nil,
                            errorStream: nil
                        )
                    )
                },
                updatePipelineStatuses: context.updatePipelineStatuses,
                pipelineExitCode: context.pipelineExitCode,
                emitVisibleOutput: { result in
                    await emitVisiblePipelineOutput(result, context: context)
                }
            )
        )
    }

    private static func runStreamingPipelineIfEligible(
        _ pipeline: MSPParsedCommandPipeline,
        context: ShellPipelineRunnerContext
    ) async -> MSPCommandResult? {
        guard ShellPipelineStagePreparer.canPreparePipelineWithoutFallback(
            pipeline,
            context: ShellPipelineStreamingPreflightContext(
                streamingCommand: context.streamingCommand,
                isShellFunctionCommand: context.shellFunctionExists,
                resolveVirtualExecutableCommandPath: context.resolveVirtualExecutableCommandPath
            )
        ) else {
            return nil
        }

        var preparedStages: [MSPStreamingPipelinePreparedStage] = []
        for index in pipeline.commands.indices {
            let redirectionOverrides = redirectionOverrides(forStageAt: index, in: pipeline)
            let stagePreparationContext = context.makeStagePreparationContext()
            switch await ShellPipelineStagePreparer.prepare(
                pipeline.commands[index],
                stageIndex: index,
                lastExitCode: context.lastExitCode,
                sourceLineNumber: context.sourceLineNumber,
                stdoutBindingOverride: redirectionOverrides.stdout,
                stderrBindingOverride: redirectionOverrides.stderr,
                context: stagePreparationContext
            ) {
            case .fallback:
                cleanupPreparedStreamingPipelineStages(
                    preparedStages,
                    cleanupProcessSubstitutions: context.cleanupProcessSubstitutions
                )
                return nil
            case .result(let preparationResult):
                applySingleCommandExpansionStateIfNeeded(preparationResult.expansionState, pipeline: pipeline, context: context)
                let result = ShellExecutionDiagnostics.prependingCommandSubstitutionStderr(
                    preparationResult.commandSubstitutionStderr,
                    to: preparationResult.result
                )
                preparedStages.append(.result(MSPStreamingPipelinePreparedResultStage(
                    result: result,
                    parsed: preparationResult.parsed,
                    startedAt: preparationResult.startedAt
                )))
            case .stage(let stage):
                applySingleCommandExpansionStateIfNeeded(stage.expansionState, pipeline: pipeline, context: context)
                preparedStages.append(.command(stage))
            }
        }

        let execution = await ShellStreamingPipelineExecutor.run(
            preparedStages: preparedStages,
            pipeOperators: pipeline.pipeOperators,
            context: ShellStreamingPipelineExecutionContext(
                outputStream: context.outputStream,
                errorStream: context.errorStream,
                fileOutputStream: context.fileOutputStream,
                makeCommandContext: context.makeStreamingCommandContext,
                emitRedirectionOutput: context.emitRedirectionOutput,
                finalizeProcessSubstitutions: context.finalizeProcessSubstitutions,
                cleanupProcessSubstitutions: context.cleanupProcessSubstitutions,
                recordAudit: context.recordAudit,
                pipelineExitCode: context.pipelineExitCode
            )
        )
        context.updatePipelineStatuses(execution.stageExitCodes)
        if pipeline.commands.count == 1, execution.result.succeeded {
            context.applyCommandStateChange(execution.result.stateChange)
        }
        return execution.result
    }

    private static func redirectionOverrides(
        forStageAt index: Int,
        in pipeline: MSPParsedCommandPipeline
    ) -> (stdout: MSPRedirectionOutputBinding?, stderr: MSPRedirectionOutputBinding?) {
        let isLast = index == pipeline.commands.count - 1
        let pipeOperator = pipeline.pipeOperators.indices.contains(index)
            ? pipeline.pipeOperators[index]
            : MSPParsedPipeOperator.stdout
        return (
            stdout: isLast ? nil : .agentStdout,
            stderr: !isLast && pipeOperator == .stdoutAndStderr ? .agentStderr : nil
        )
    }

    private static func applySingleCommandExpansionStateIfNeeded(
        _ expansionState: MSPShellExpansionState?,
        pipeline: MSPParsedCommandPipeline,
        context: ShellPipelineRunnerContext
    ) {
        guard pipeline.commands.count == 1, let expansionState else {
            return
        }
        context.applyExpansionState(expansionState)
    }

    private static func singleCommandStreamsOutputInternally(
        _ command: MSPParsedCommandLine,
        shellFunctionExists: (String) -> Bool
    ) -> Bool {
        command.structuredCompoundCommand != nil
            || command.compoundCommand != nil
            || command.commandName.contains("/")
            || command.commandName == "eval"
            || command.commandName == "."
            || command.commandName == "source"
            || RuntimeShellLauncherNames.shellLauncherName(for: command.commandName) != nil
            || shellFunctionExists(command.commandName)
    }

    private static func cleanupPreparedStreamingPipelineStages(
        _ stages: [MSPStreamingPipelinePreparedStage],
        cleanupProcessSubstitutions: (Int) -> Void
    ) {
        let startIndexes = stages.compactMap { stage -> Int? in
            guard case .command(let commandStage) = stage else {
                return nil
            }
            return commandStage.processSubstitutionStartIndex
        }
        guard let startIndex = startIndexes.min() else {
            return
        }
        cleanupProcessSubstitutions(startIndex)
    }

    private static func pipelineResult(
        _ result: MSPCommandResult,
        pipeline: MSPParsedCommandPipeline
    ) -> MSPCommandResult {
        ShellPipelineStatus.result(result, isNegated: pipeline.isNegated)
    }

    private static func emitVisiblePipelineOutput(
        _ result: MSPCommandResult,
        context: ShellPipelineRunnerContext
    ) async -> MSPCommandResult {
        await ShellOutputForwarding.emitVisibleOutput(
            result,
            outputStream: context.outputStream,
            errorStream: context.errorStream,
            emitProbe: context.emitStreamProbe
        )
    }
}
