import Foundation
import MSPCore
import MSPShell

struct ShellRuntimePipelineRunOptions {
    var fullCommandLine: String
    var lastExitCode: Int32
    var sourceLineNumber: Int?
    var outputStream: (any MSPCommandOutputStream)?
    var errorStream: (any MSPCommandOutputStream)?
}

struct ShellRuntimePipelinePorts {
    var singleCommandPorts: ShellRuntimeSingleCommandPorts
    var makeExpansionContext: @Sendable (Bool, Int32) async throws -> MSPShellExpansionContext
    var runCommandSubstitution: @Sendable (String, Data, Bool, Bool, Int32) async -> MSPShellCommandSubstitutionResult
    var resolveProcessSubstitution: @Sendable (
        MSPShellProcessSubstitutionRequest,
        Data,
        Bool,
        Bool,
        Int32
    ) async throws -> MSPShellProcessSubstitutionResult
    var cleanupProcessSubstitutions: @Sendable (Int) -> Void
    var expansionFailureResult: @Sendable (MSPShellExpansionError) -> MSPCommandResult
    var redirectionFailureResult: @Sendable (MSPCommandResult, Int?) -> MSPCommandResult
    var applyRedirections: @Sendable (
        [MSPParsedRedirection],
        Data,
        Bool,
        Bool,
        String,
        MSPRedirectionOutputBinding?,
        MSPRedirectionOutputBinding?
    ) throws -> MSPRedirectionRouting
    var fileOutputStream: @Sendable (MSPRedirectionFileSink) -> (any MSPCommandOutputStream)?
    var makeStreamingCommandContext: @Sendable (
        MSPStreamingPipelineStage,
        any MSPCommandInputStream,
        any MSPCommandOutputStream,
        any MSPCommandOutputStream
    ) -> MSPCommandContext
    var emitRedirectionOutput: @Sendable (
        Data,
        MSPRedirectionOutputBinding,
        inout Data,
        inout Data,
        inout Set<String>
    ) throws -> Void
    var finalizeProcessSubstitutions: @Sendable (Int, MSPCommandResult) async throws -> MSPCommandResult
    var recordAudit: @Sendable (MSPParsedCommandLine, String, MSPCommandResult, Date) async -> Void
    var applyCommandStateChange: @Sendable (MSPCommandRuntimeStateChange?) -> Void
    var emitStreamProbe: @Sendable (String, [String: String]) -> Void
}

extension ShellRuntime {
    func runPipeline(
        _ pipeline: MSPParsedCommandPipeline,
        options: ShellRuntimePipelineRunOptions,
        ports: ShellRuntimePipelinePorts
    ) async -> MSPCommandResult {
        await ShellPipelineRunner.run(
            pipeline,
            context: ShellPipelineRunnerContext(
                fullCommandLine: options.fullCommandLine,
                lastExitCode: options.lastExitCode,
                sourceLineNumber: options.sourceLineNumber,
                initialStandardInput: configuration.standardInput,
                initialStandardInputClosed: configuration.standardInputClosed,
                outputStream: options.outputStream,
                errorStream: options.errorStream,
                runCommand: { [self] command, request in
                    await runSingleCommand(
                        command,
                        options: ShellRuntimeSingleCommandRunOptions(
                            fullCommandLine: request.fullCommandLine,
                            standardInput: request.standardInput,
                            standardInputClosed: request.standardInputClosed,
                            standardInputOverridesFileDescriptor: request.standardInputOverridesFileDescriptor,
                            stdoutBindingOverride: request.stdoutBindingOverride,
                            stderrBindingOverride: request.stderrBindingOverride,
                            appliesStateChange: request.appliesStateChange,
                            lastExitCode: request.lastExitCode,
                            sourceLineNumber: request.sourceLineNumber,
                            outputStream: request.outputStream,
                            errorStream: request.errorStream
                        ),
                        ports: ports.singleCommandPorts
                    )
                },
                streamingCommand: { [registry] name in
                    registry.command(named: name) as? any MSPStreamingCommand
                },
                shellFunctionExists: { [self] name in
                    shellFunctionExists(name)
                },
                resolveVirtualExecutableCommandPath: { [registry, ports] commandPath in
                    ShellVirtualExecutableCommandPath.commandName(
                        for: commandPath,
                        registryCommandNames: registry.commandNames,
                        commandLookupPaths: ports.singleCommandPorts.availableCommandLookupPaths()
                    )
                },
                makeStagePreparationContext: { [self] in
                    pipelineStagePreparationContext(
                        lastExitCode: options.lastExitCode,
                        ports: ports
                    )
                },
                fileOutputStream: ports.fileOutputStream,
                makeStreamingCommandContext: ports.makeStreamingCommandContext,
                emitRedirectionOutput: ports.emitRedirectionOutput,
                finalizeProcessSubstitutions: ports.finalizeProcessSubstitutions,
                cleanupProcessSubstitutions: ports.cleanupProcessSubstitutions,
                recordAudit: { parsed, result, startedAt in
                    await ports.recordAudit(
                        parsed,
                        options.fullCommandLine,
                        result,
                        startedAt
                    )
                },
                applyExpansionState: { [self] expansionState in
                    applyExpansionState(expansionState)
                },
                applyCommandStateChange: ports.applyCommandStateChange,
                updatePipelineStatuses: { [self] stageExitCodes in
                    updatePipelineStatuses(stageExitCodes)
                },
                pipelineExitCode: { [self] stageExitCodes in
                    pipelineExitCode(stageExitCodes)
                },
                emitStreamProbe: ports.emitStreamProbe
            )
        )
    }

    private func pipelineStagePreparationContext(
        lastExitCode: Int32,
        ports: ShellRuntimePipelinePorts
    ) -> ShellPipelineStagePreparationContext {
        ShellPipelineStagePreparationContext(
            commandContextSeed: ShellPipelineCommandContextSeed(configuration: configuration),
            processSubstitutionStartIndex: io.processSubstitutionCheckpoint,
            enablesExtendedGlob: shellOptionEnabled("extglob"),
            streamingCommand: { [registry] name in
                registry.command(named: name) as? any MSPStreamingCommand
            },
            isShellFunctionCommand: { [self] name in
                shellFunctionExists(name)
            },
            resolveVirtualExecutableCommandPath: { [registry, ports] commandPath in
                ShellVirtualExecutableCommandPath.commandName(
                    for: commandPath,
                    registryCommandNames: registry.commandNames,
                    commandLookupPaths: ports.singleCommandPorts.availableCommandLookupPaths()
                )
            },
            commandCanRunWithPathSearch: { [self, ports] parsed, resolvedExplicitVirtualExecutablePath in
                let commandEnvironment = exportedEnvironment(
                    from: configuration.environment,
                    applying: parsed.assignments
                )
                return ShellVirtualExecutableCommandPath.commandCanRunWithPathSearch(
                    commandName: parsed.commandName,
                    resolvedExplicitVirtualExecutablePath: resolvedExplicitVirtualExecutablePath,
                    availableCommandNames: ports.singleCommandPorts.availableCommandNames(),
                    commandLookupPaths: ports.singleCommandPorts.availableCommandLookupPaths(),
                    environmentPath: commandEnvironment["PATH"]
                )
            },
            makeExpansionContext: { requiresPathnameCandidates in
                try await ports.makeExpansionContext(requiresPathnameCandidates, lastExitCode)
            },
            runCommandSubstitution: ports.runCommandSubstitution,
            resolveProcessSubstitution: ports.resolveProcessSubstitution,
            cleanupProcessSubstitutions: ports.cleanupProcessSubstitutions,
            expansionFailureResult: ports.expansionFailureResult,
            redirectionFailureResult: ports.redirectionFailureResult,
            applyRedirections: ports.applyRedirections
        )
    }
}
