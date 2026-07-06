import Foundation
import MSPCore
import MSPShell

extension ShellSingleCommandExecutor {
    static func runReentryDispatch(
        _ dispatch: ShellCommandDispatch,
        parsed: MSPParsedCommandLine,
        fullCommandLine: String,
        commandSubstitutionStderr: String,
        routing: MSPRedirectionRouting,
        touchedFileDescriptors: Set<Int>,
        processSubstitutionStartIndex: Int,
        startedAt: Date,
        context: ShellSingleCommandExecutionContext
    ) async -> MSPCommandResult? {
        let frame = context.frame

        switch dispatch {
        case .evalBuiltin:
            let outputScope = IORuntimeState.redirectionOutputScope(
                for: parsed.redirections,
                stdoutBindingOverride: frame.stdoutBindingOverride,
                stderrBindingOverride: frame.stderrBindingOverride
            )
            let result = await context.runWithScopedFileDescriptorRouting(
                routing,
                touchedFileDescriptors
            ) {
                await context.handlers.reentry.executeEvalCommand(
                    ShellSingleCommandEvalRequest(
                        arguments: parsed.arguments,
                        io: ShellSingleCommandReentryIO(
                            standardInput: routing.standardInput,
                            standardInputClosed: routing.standardInputClosed,
                            stdoutBinding: outputScope.stdout
                                ? context.scopedOutputBinding(routing.stdoutBinding)
                                : nil,
                            stderrBinding: outputScope.stderr
                                ? context.scopedOutputBinding(routing.stderrBinding)
                                : nil,
                            lastExitCode: frame.lastExitCode,
                            outputStream: frame.outputStream,
                            errorStream: frame.errorStream
                        ),
                        appliesStateChange: frame.appliesStateChange,
                        hasInputRedirection: IORuntimeState.redirectionsScopeStandardInput(parsed.redirections)
                    )
                )
            }
            return await finalizeAndAudit(
                result,
                parsed: parsed,
                fullCommandLine: fullCommandLine,
                commandSubstitutionStderr: commandSubstitutionStderr,
                routing: routing,
                processSubstitutionStartIndex: processSubstitutionStartIndex,
                startedAt: startedAt,
                context: context
            )

        case .sourceBuiltin:
            let result = await runScopedCommand(
                parsed: parsed,
                routing: routing,
                touchedFileDescriptors: touchedFileDescriptors,
                context: context
            ) { stdoutBinding, stderrBinding in
                await context.handlers.reentry.executeSourceCommand(
                    ShellSingleCommandSourceRequest(
                        commandName: parsed.commandName,
                        arguments: parsed.arguments,
                        io: reentryIO(
                            routing: routing,
                            stdoutBinding: stdoutBinding,
                            stderrBinding: stderrBinding,
                            context: context
                        ),
                        appliesStateChange: frame.appliesStateChange
                    )
                )
            }
            return await finalizeAndAudit(
                result,
                parsed: parsed,
                fullCommandLine: fullCommandLine,
                commandSubstitutionStderr: commandSubstitutionStderr,
                routing: routing,
                processSubstitutionStartIndex: processSubstitutionStartIndex,
                startedAt: startedAt,
                context: context
            )

        case .shellLauncher(let shellLauncherName):
            let result = await runScopedCommand(
                parsed: parsed,
                routing: routing,
                touchedFileDescriptors: touchedFileDescriptors,
                context: context
            ) { stdoutBinding, stderrBinding in
                await context.handlers.reentry.executeShellLauncherCommand(
                    ShellSingleCommandShellLauncherRequest(
                        commandName: parsed.commandName,
                        shellLauncherName: shellLauncherName,
                        arguments: parsed.arguments,
                        io: reentryIO(
                            routing: routing,
                            stdoutBinding: stdoutBinding,
                            stderrBinding: stderrBinding,
                            context: context
                        )
                    )
                )
            }
            return await finalizeAndAudit(
                result,
                parsed: parsed,
                fullCommandLine: fullCommandLine,
                commandSubstitutionStderr: commandSubstitutionStderr,
                routing: routing,
                processSubstitutionStartIndex: processSubstitutionStartIndex,
                startedAt: startedAt,
                context: context
            )

        case .structuredCompound(let compoundCommand):
            let result = await runScopedCommand(
                parsed: parsed,
                routing: routing,
                touchedFileDescriptors: touchedFileDescriptors,
                context: context
            ) { stdoutBinding, stderrBinding in
                await context.handlers.reentry.runCompoundCommand(
                    ShellSingleCommandCompoundRequest(
                        compoundCommand: compoundCommand,
                        io: reentryIO(
                            routing: routing,
                            stdoutBinding: stdoutBinding,
                            stderrBinding: stderrBinding,
                            context: context
                        ),
                        appliesStateChange: frame.appliesStateChange,
                        sourceLineNumber: frame.sourceLineNumber
                    )
                )
            }
            return await finalizeAndAudit(
                result,
                parsed: parsed,
                fullCommandLine: fullCommandLine,
                commandSubstitutionStderr: commandSubstitutionStderr,
                routing: routing,
                processSubstitutionStartIndex: processSubstitutionStartIndex,
                startedAt: startedAt,
                context: context
            )

        case .shellFunction(let functionDefinition, let diagnosticSourceName):
            let isolatedState = frame.appliesStateChange ? nil : context.handlers.reentry.saveShellRuntimeState()
            let result = await runScopedCommand(
                parsed: parsed,
                routing: routing,
                touchedFileDescriptors: touchedFileDescriptors,
                context: context
            ) { stdoutBinding, stderrBinding in
                await context.handlers.reentry.executeShellFunction(
                    ShellSingleCommandFunctionRequest(
                        functionDefinition: functionDefinition,
                        diagnosticSourceName: diagnosticSourceName,
                        arguments: parsed.arguments,
                        assignments: parsed.assignments,
                        io: reentryIO(
                            routing: routing,
                            stdoutBinding: stdoutBinding,
                            stderrBinding: stderrBinding,
                            context: context
                        )
                    )
                )
            }
            if let isolatedState {
                context.handlers.reentry.restoreShellRuntimeState(isolatedState)
            }
            return await finalizeAndAudit(
                result,
                parsed: parsed,
                fullCommandLine: fullCommandLine,
                commandSubstitutionStderr: commandSubstitutionStderr,
                routing: routing,
                processSubstitutionStartIndex: processSubstitutionStartIndex,
                startedAt: startedAt,
                context: context
            )

        case .pathScript:
            let result = await runScopedCommand(
                parsed: parsed,
                routing: routing,
                touchedFileDescriptors: touchedFileDescriptors,
                context: context
            ) { stdoutBinding, stderrBinding in
                await context.handlers.reentry.executePathScriptCommand(
                    ShellSingleCommandPathScriptRequest(
                        commandName: parsed.commandName,
                        arguments: parsed.arguments,
                        io: reentryIO(
                            routing: routing,
                            stdoutBinding: stdoutBinding,
                            stderrBinding: stderrBinding,
                            context: context
                        ),
                        sourceLineNumber: frame.sourceLineNumber
                    )
                )
            }
            return await finalizeAndAudit(
                result,
                parsed: parsed,
                fullCommandLine: fullCommandLine,
                commandSubstitutionStderr: commandSubstitutionStderr,
                routing: routing,
                processSubstitutionStartIndex: processSubstitutionStartIndex,
                startedAt: startedAt,
                mapsRedirectionFailureToShellDiagnostic: true,
                context: context
            )

        case .functionDefinition,
             .execBuiltin,
             .returnBuiltin,
             .loopControlBuiltin,
             .exitBuiltin,
             .shiftBuiltin,
             .setBuiltin,
             .shoptBuiltin,
             .declarationBuiltin,
             .variableAttributeBuiltin,
             .aliasBuiltin,
             .trapBuiltin,
             .umaskBuiltin,
             .unsetBuiltin,
             .localBuiltin,
             .readBuiltin,
             .mapfileBuiltin,
             .arithmetic,
             .assignmentOnly,
             .doubleBracketRegex,
             .registryCommand:
            return nil
        }
    }

    private static func reentryIO(
        routing: MSPRedirectionRouting,
        stdoutBinding: MSPRedirectionOutputBinding?,
        stderrBinding: MSPRedirectionOutputBinding?,
        context: ShellSingleCommandExecutionContext
    ) -> ShellSingleCommandReentryIO {
        let frame = context.frame
        return ShellSingleCommandReentryIO(
            standardInput: routing.standardInput,
            standardInputClosed: routing.standardInputClosed,
            stdoutBinding: stdoutBinding,
            stderrBinding: stderrBinding,
            lastExitCode: frame.lastExitCode,
            outputStream: frame.outputStream,
            errorStream: frame.errorStream
        )
    }
}
