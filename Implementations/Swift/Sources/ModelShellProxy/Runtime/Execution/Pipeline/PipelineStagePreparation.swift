import Foundation
import MSPCore
import MSPShell

struct ShellPipelineStagePreparationContext {
    var commandContextSeed: ShellPipelineCommandContextSeed
    var processSubstitutionStartIndex: Int
    var enablesExtendedGlob: Bool
    var streamingCommand: @Sendable (String) -> (any MSPStreamingCommand)?
    var isShellFunctionCommand: @Sendable (String) -> Bool
    var resolveVirtualExecutableCommandPath: @Sendable (String) -> String?
    var commandCanRunWithPathSearch: @Sendable (MSPParsedCommandLine, Bool) -> Bool
    var makeExpansionContext: @Sendable (Bool) async throws -> MSPShellExpansionContext
    var runCommandSubstitution: @Sendable (String, Data, Bool, Bool, Int32) async -> MSPShellCommandSubstitutionResult
    var resolveProcessSubstitution: @Sendable (MSPShellProcessSubstitutionRequest, Data, Bool, Bool, Int32) async throws -> MSPShellProcessSubstitutionResult
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
}

struct ShellPipelineStreamingPreflightContext {
    var streamingCommand: @Sendable (String) -> (any MSPStreamingCommand)?
    var isShellFunctionCommand: @Sendable (String) -> Bool
    var resolveVirtualExecutableCommandPath: @Sendable (String) -> String?
}

enum ShellPipelineStagePreparer {
    static func canPreparePipelineWithoutFallback(
        _ pipeline: MSPParsedCommandPipeline,
        context: ShellPipelineStreamingPreflightContext
    ) -> Bool {
        pipeline.commands.allSatisfy {
            canPrepareStageWithoutFallback($0, context: context)
        }
    }

    private static func canPrepareStageWithoutFallback(
        _ rawParsed: MSPParsedCommandLine,
        context: ShellPipelineStreamingPreflightContext
    ) -> Bool {
        let commandName = context.resolveVirtualExecutableCommandPath(rawParsed.commandName)
            ?? rawParsed.commandName
        guard rawParsed.functionDefinition == nil,
              rawParsed.structuredCompoundCommand == nil,
              rawParsed.compoundCommand == nil,
              rawParsed.compoundKind == nil,
              rawParsed.arithmeticExpression == nil,
              !rawParsed.isAssignmentOnly,
              !commandName.contains("/"),
              !commandNameRequiresExpansion(rawParsed.commandNameWord),
              !context.isShellFunctionCommand(commandName),
              context.streamingCommand(commandName) != nil
        else {
            return false
        }
        return true
    }

    private static func commandNameRequiresExpansion(_ word: MSPParsedWord?) -> Bool {
        guard let word else {
            return false
        }
        return word.parts.contains { part in
            part.isExpandable
                && (part.text.contains("$")
                    || part.text.contains("`")
                    || part.text.contains("<(")
                    || part.text.contains(">("))
        }
    }

    static func prepare(
        _ rawParsed: MSPParsedCommandLine,
        stageIndex: Int,
        lastExitCode: Int32,
        sourceLineNumber: Int?,
        stdoutBindingOverride: MSPRedirectionOutputBinding?,
        stderrBindingOverride: MSPRedirectionOutputBinding?,
        context: ShellPipelineStagePreparationContext
    ) async -> MSPStreamingPipelineStagePreparation {
        let startedAt = Date()
        let processSubstitutionStartIndex = context.processSubstitutionStartIndex
        let stageStandardInput = stageIndex == 0 ? context.commandContextSeed.standardInput : Data()
        let stageStandardInputClosed = stageIndex == 0 ? context.commandContextSeed.standardInputClosed : false
        let stageOverridesStandardInputFileDescriptor = stageIndex > 0
        let parsed: MSPParsedCommandLine
        let commandSubstitutionStderr: String
        let expansionState: MSPShellExpansionState
        let resolvedExplicitVirtualExecutablePath: Bool
        let runCommandSubstitution = context.runCommandSubstitution
        let resolveProcessSubstitution = context.resolveProcessSubstitution
        func preparationResult(
            _ result: MSPCommandResult,
            parsed: MSPParsedCommandLine,
            commandSubstitutionStderr: String = "",
            expansionState: MSPShellExpansionState? = nil
        ) -> MSPStreamingPipelineStagePreparation {
            .result(MSPStreamingPipelinePreparationResult(
                result: result,
                parsed: parsed,
                commandSubstitutionStderr: commandSubstitutionStderr,
                expansionState: expansionState,
                startedAt: startedAt
            ))
        }
        do {
            let expansion = try await rawParsed.expandedResolvingCommandSubstitutions(
                in: try await context.makeExpansionContext(
                    rawParsed.mspMayNeedPathnameExpansionCandidates(
                        enablesExtendedGlob: context.enablesExtendedGlob
                    )
                ),
                resolver: { commandLine in
                    await runCommandSubstitution(
                        commandLine,
                        stageStandardInput,
                        stageStandardInputClosed,
                        stageOverridesStandardInputFileDescriptor,
                        lastExitCode
                    )
                },
                processSubstitutionResolver: { request in
                    try await resolveProcessSubstitution(
                        request,
                        stageStandardInput,
                        stageStandardInputClosed,
                        stageOverridesStandardInputFileDescriptor,
                        lastExitCode
                    )
                }
            )
            var expandedCommand = expansion.commandLine
            if let resolvedCommandName = context.resolveVirtualExecutableCommandPath(expandedCommand.commandName) {
                resolvedExplicitVirtualExecutablePath = expandedCommand.commandName.contains("/")
                expandedCommand.commandName = resolvedCommandName
            } else {
                resolvedExplicitVirtualExecutablePath = false
            }
            parsed = expandedCommand
            commandSubstitutionStderr = expansion.stderr
            expansionState = expansion.state
        } catch let expansionError as MSPShellExpansionError {
            context.cleanupProcessSubstitutions(processSubstitutionStartIndex)
            return preparationResult(
                context.expansionFailureResult(expansionError),
                parsed: rawParsed
            )
        } catch {
            context.cleanupProcessSubstitutions(processSubstitutionStartIndex)
            return preparationResult(
                MSPCommandResult.failure(exitCode: 1, stderr: "shell: \(error)\n"),
                parsed: rawParsed
            )
        }

        guard parsed.functionDefinition == nil,
              parsed.structuredCompoundCommand == nil,
              parsed.compoundCommand == nil,
              parsed.arithmeticExpression == nil,
              !parsed.isAssignmentOnly,
              !parsed.commandName.contains("/"),
              !context.isShellFunctionCommand(parsed.commandName),
              context.commandCanRunWithPathSearch(parsed, resolvedExplicitVirtualExecutablePath),
              let command = context.streamingCommand(parsed.commandName)
        else {
            context.cleanupProcessSubstitutions(processSubstitutionStartIndex)
            return .fallback
        }

        let policyRequest = MSPPolicyRequest(
            commandName: parsed.commandName,
            arguments: parsed.arguments,
            currentDirectory: context.commandContextSeed.currentDirectory
        )
        switch await context.commandContextSeed.policyEngine.evaluate(policyRequest) {
        case .allow:
            break
        case .deny(let reason):
            context.cleanupProcessSubstitutions(processSubstitutionStartIndex)
            return preparationResult(
                MSPCommandResult.failure(exitCode: 126, stderr: "\(parsed.commandName): \(reason)\n"),
                parsed: parsed,
                commandSubstitutionStderr: commandSubstitutionStderr
            )
        case .requiresConfirmation(let prompt):
            context.cleanupProcessSubstitutions(processSubstitutionStartIndex)
            return preparationResult(
                MSPCommandResult.failure(exitCode: 126, stderr: "\(parsed.commandName): confirmation required: \(prompt)\n"),
                parsed: parsed,
                commandSubstitutionStderr: commandSubstitutionStderr
            )
        }

        let routing: MSPRedirectionRouting
        do {
            routing = try context.applyRedirections(
                parsed.redirections,
                stageStandardInput,
                stageIndex == 0 ? context.commandContextSeed.standardInputClosed : false,
                stageOverridesStandardInputFileDescriptor,
                context.commandContextSeed.currentDirectory,
                stdoutBindingOverride,
                stderrBindingOverride
            )
        } catch let failure as MSPCommandFailure {
            context.cleanupProcessSubstitutions(processSubstitutionStartIndex)
            return preparationResult(
                context.redirectionFailureResult(failure.result, sourceLineNumber),
                parsed: parsed,
                commandSubstitutionStderr: commandSubstitutionStderr,
                expansionState: expansionState
            )
        } catch {
            context.cleanupProcessSubstitutions(processSubstitutionStartIndex)
            return preparationResult(
                MSPCommandResult.failure(exitCode: 1, stderr: "\(parsed.commandName): \(error)\n"),
                parsed: parsed,
                commandSubstitutionStderr: commandSubstitutionStderr,
                expansionState: expansionState
            )
        }

        return .stage(MSPStreamingPipelineStage(
            command: command,
            invocation: MSPCommandInvocation(
                name: parsed.commandName,
                arguments: parsed.arguments,
                rawInput: parsed.rawInput
            ),
            parsed: parsed,
            commandContextSeed: context.commandContextSeed,
            routing: routing,
            usesPipeInput: stageIndex > 0 && !IORuntimeState.redirectionsScopeStandardInput(parsed.redirections),
            assignments: parsed.assignments,
            commandSubstitutionStderr: commandSubstitutionStderr,
            expansionState: expansionState,
            startedAt: startedAt,
            processSubstitutionStartIndex: processSubstitutionStartIndex
        ))
    }
}
