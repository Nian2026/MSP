import Foundation
import MSPCore
import MSPShell

extension ShellSingleCommandExecutor {
    static func runBuiltinDispatch(
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
        case .returnBuiltin:
            let result = context.handlers.builtins.executeReturnCommand(parsed.arguments, frame.lastExitCode)
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

        case .loopControlBuiltin:
            let result = context.handlers.builtins.executeLoopControlCommand(
                parsed.commandName,
                parsed.arguments,
                frame.appliesStateChange
            )
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

        case .exitBuiltin:
            let result = context.handlers.builtins.executeExitCommand(
                parsed.arguments,
                frame.lastExitCode,
                frame.appliesStateChange
            )
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

        case .shiftBuiltin:
            let result = context.handlers.builtins.executeShiftCommand(parsed.arguments, frame.appliesStateChange)
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

        case .setBuiltin:
            let xtraceStderr = context.xtraceDiagnostic(parsed)
            let result = context.handlers.builtins.executeSetCommand(parsed.arguments, frame.appliesStateChange)
            return await finalizeAndAudit(
                result,
                parsed: parsed,
                fullCommandLine: fullCommandLine,
                commandSubstitutionStderr: commandSubstitutionStderr,
                routing: routing,
                processSubstitutionStartIndex: processSubstitutionStartIndex,
                startedAt: startedAt,
                xtraceStderr: xtraceStderr,
                context: context
            )

        case .shoptBuiltin:
            let result = context.handlers.builtins.executeShoptCommand(parsed.arguments, frame.appliesStateChange)
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

        case .declarationBuiltin:
            let result = context.handlers.builtins.executeDeclareCommand(
                parsed.commandName,
                parsed.arguments,
                frame.appliesStateChange
            )
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

        case .variableAttributeBuiltin:
            let result = context.handlers.builtins.executeVariableAttributeCommand(
                parsed.commandName,
                parsed.arguments,
                frame.appliesStateChange
            )
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

        case .aliasBuiltin:
            let result = context.handlers.builtins.executeAliasCommand(
                parsed.commandName,
                parsed.arguments,
                frame.appliesStateChange
            )
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

        case .trapBuiltin:
            let result = context.handlers.builtins.executeTrapCommand(parsed.arguments, frame.appliesStateChange)
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

        case .umaskBuiltin:
            let result = context.handlers.builtins.executeUmaskCommand(parsed.arguments, frame.appliesStateChange)
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

        case .unsetBuiltin:
            let result = context.handlers.builtins.executeUnsetCommand(parsed.arguments, frame.appliesStateChange)
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

        case .localBuiltin:
            let result = context.handlers.builtins.executeLocalCommand(parsed.arguments, frame.appliesStateChange)
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

        case .readBuiltin:
            let result = await context.handlers.builtins.executeReadCommand(
                parsed.arguments,
                routing,
                parsed.assignments,
                frame.appliesStateChange
            )
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

        case .mapfileBuiltin:
            let result = await context.handlers.builtins.executeMapfileCommand(
                parsed.commandName,
                parsed.arguments,
                routing,
                frame.appliesStateChange
            )
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

        case .arithmetic(let arithmeticExpression):
            let result = context.handlers.builtins.executeArithmeticCommand(
                arithmeticExpression,
                frame.appliesStateChange
            )
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

        case .assignmentOnly:
            var result = await finalizedResult(
                .success(),
                parsed: parsed,
                routing: routing,
                processSubstitutionStartIndex: processSubstitutionStartIndex,
                context: context
            )
            result = context.withCommandSubstitutionStderr(commandSubstitutionStderr, result)
            if frame.appliesStateChange, result.succeeded {
                context.handlers.builtins.applyAssignmentOnlyStateChange(parsed)
            }
            await recordParsedCommandAudit(
                parsed: parsed,
                fullCommandLine: fullCommandLine,
                result: result,
                startedAt: startedAt,
                context: context
            )
            return result

        case .doubleBracketRegex:
            let result = await context.runWithScopedFileDescriptorRouting(
                routing,
                touchedFileDescriptors
            ) {
                context.handlers.builtins.executeDoubleBracketRegexCommand(
                    parsed.arguments,
                    frame.appliesStateChange
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

        case .functionDefinition,
             .execBuiltin,
             .evalBuiltin,
             .sourceBuiltin,
             .shellLauncher,
             .structuredCompound,
             .shellFunction,
             .pathScript,
             .registryCommand:
            return nil
        }
    }
}
