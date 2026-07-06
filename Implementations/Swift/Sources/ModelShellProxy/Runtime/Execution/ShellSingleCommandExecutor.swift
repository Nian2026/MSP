import Foundation
import MSPCore
import MSPShell

enum ShellSingleCommandExecutor {
    static func run(
        _ rawParsed: MSPParsedCommandLine,
        fullCommandLine: String,
        context: ShellSingleCommandExecutionContext
    ) async -> MSPCommandResult {
        let startedAt = Date()
        let frame = context.frame
        let processSubstitutionStartIndex = context.processSubstitutionCheckpoint()

        let parsed: MSPParsedCommandLine
        let commandSubstitutionStderr: String
        let resolvedExplicitVirtualExecutablePath: Bool
        do {
            let expansion = try await context.expandCommandLine(rawParsed, frame)
            var expandedCommand = expansion.commandLine
            if let resolvedCommandName = context.resolveVirtualExecutableCommandPath(expandedCommand.commandName) {
                resolvedExplicitVirtualExecutablePath = expandedCommand.commandName.contains("/")
                expandedCommand.commandName = resolvedCommandName
            } else {
                resolvedExplicitVirtualExecutablePath = false
            }
            parsed = expandedCommand
            commandSubstitutionStderr = expansion.stderr
            if frame.appliesStateChange {
                context.applyExpansionState(expansion)
            }
        } catch let expansionError as MSPShellExpansionError {
            context.cleanupProcessSubstitutionTemporaryPaths(processSubstitutionStartIndex)
            let result = context.expansionFailureResult(expansionError)
            if frame.appliesStateChange {
                context.setPendingShellExitCode(result.exitCode)
            }
            await context.recordAudit(rawParsed.rawInput, rawParsed, result, startedAt)
            return result
        } catch {
            context.cleanupProcessSubstitutionTemporaryPaths(processSubstitutionStartIndex)
            let result = MSPCommandResult.failure(exitCode: 1, stderr: "shell: \(error)\n")
            await context.recordAudit(rawParsed.rawInput, rawParsed, result, startedAt)
            return result
        }

        let policyRequest = MSPPolicyRequest(
            commandName: parsed.commandName,
            arguments: parsed.arguments,
            currentDirectory: context.currentDirectory()
        )
        switch await context.evaluatePolicy(policyRequest) {
        case .allow:
            break
        case .deny(let reason):
            let result = context.withCommandSubstitutionStderr(
                commandSubstitutionStderr,
                MSPCommandResult.failure(exitCode: 126, stderr: "\(parsed.commandName): \(reason)\n")
            )
            context.cleanupProcessSubstitutionTemporaryPaths(processSubstitutionStartIndex)
            await context.recordAudit(parsed.rawInput, parsed, result, startedAt)
            return result
        case .requiresConfirmation(let prompt):
            let result = context.withCommandSubstitutionStderr(
                commandSubstitutionStderr,
                MSPCommandResult.failure(
                    exitCode: 126,
                    stderr: "\(parsed.commandName): confirmation required: \(prompt)\n"
                )
            )
            context.cleanupProcessSubstitutionTemporaryPaths(processSubstitutionStartIndex)
            await context.recordAudit(parsed.rawInput, parsed, result, startedAt)
            return result
        }

        let dispatch = context.dispatch(parsed)

        if case .functionDefinition(let functionDefinition) = dispatch {
            context.handlers.preRedirection.storeFunctionDefinition(functionDefinition, frame.appliesStateChange)
            let result = context.withCommandSubstitutionStderr(commandSubstitutionStderr, .success())
            context.cleanupProcessSubstitutionTemporaryPaths(processSubstitutionStartIndex)
            await recordParsedCommandAudit(
                parsed: parsed,
                fullCommandLine: fullCommandLine,
                result: result,
                startedAt: startedAt,
                context: context
            )
            return result
        }

        if case .execBuiltin = dispatch {
            let pathsBefore = context.handlers.preRedirection.persistentOutputProcessSubstitutionPaths()
            var result = context.handlers.preRedirection.executeExecCommand(
                parsed.arguments,
                parsed.redirections,
                frame.appliesStateChange
            )
            if result.succeeded {
                do {
                    result = try await context.handlers.preRedirection.appendClosedPersistentOutputProcessSubstitutions(
                        pathsBefore,
                        result
                    )
                } catch let failure as MSPCommandFailure {
                    result = failure.result
                } catch {
                    result = .failure(exitCode: 1, stderr: "exec: \(error)\n")
                }
            }
            context.cleanupProcessSubstitutionTemporaryPaths(processSubstitutionStartIndex)
            result = context.withCommandSubstitutionStderr(commandSubstitutionStderr, result)
            await recordParsedCommandAudit(
                parsed: parsed,
                fullCommandLine: fullCommandLine,
                result: result,
                startedAt: startedAt,
                context: context
            )
            return result
        }

        let redirectionRouting: MSPRedirectionRouting
        do {
            redirectionRouting = try context.applyRedirections(parsed.redirections, frame)
        } catch let failure as MSPCommandFailure {
            let result = context.withCommandSubstitutionStderr(
                commandSubstitutionStderr,
                context.shellRedirectionFailureResult(failure.result, frame.sourceLineNumber)
            )
            context.cleanupProcessSubstitutionTemporaryPaths(processSubstitutionStartIndex)
            await context.recordAudit(parsed.rawInput, parsed, result, startedAt)
            return result
        } catch {
            let result = context.withCommandSubstitutionStderr(
                commandSubstitutionStderr,
                MSPCommandResult.failure(exitCode: 1, stderr: "\(parsed.commandName): \(error)\n")
            )
            context.cleanupProcessSubstitutionTemporaryPaths(processSubstitutionStartIndex)
            await context.recordAudit(parsed.rawInput, parsed, result, startedAt)
            return result
        }

        if !context.commandCanRunWithPathSearch(dispatch, parsed, resolvedExplicitVirtualExecutablePath) {
            let xtraceStderr = context.xtraceDiagnostic(parsed)
            var result = MSPCommandResult.failure(exitCode: 127, stderr: "\(parsed.commandName): command not found\n")
            result = context.handlers.registry.shellCommandLookupFailureResult(
                result,
                parsed.commandName,
                frame.sourceLineNumber
            )
            result = await finalizedResult(
                result,
                parsed: parsed,
                routing: redirectionRouting,
                processSubstitutionStartIndex: processSubstitutionStartIndex,
                commandNameForFinalize: parsed.commandName,
                context: context
            )
            result = context.withXtraceStderr(xtraceStderr, result)
            result = context.withCommandSubstitutionStderr(commandSubstitutionStderr, result)
            await recordParsedCommandAudit(
                parsed: parsed,
                fullCommandLine: fullCommandLine,
                result: result,
                startedAt: startedAt,
                context: context
            )
            return result
        }

        let touchedFileDescriptors = IORuntimeState.redirectionTouchedFileDescriptors(parsed.redirections)
        if let result = await runBuiltinDispatch(
            dispatch,
            parsed: parsed,
            fullCommandLine: fullCommandLine,
            commandSubstitutionStderr: commandSubstitutionStderr,
            routing: redirectionRouting,
            touchedFileDescriptors: touchedFileDescriptors,
            processSubstitutionStartIndex: processSubstitutionStartIndex,
            startedAt: startedAt,
            context: context
        ) {
            return result
        }
        if let result = await runReentryDispatch(
            dispatch,
            parsed: parsed,
            fullCommandLine: fullCommandLine,
            commandSubstitutionStderr: commandSubstitutionStderr,
            routing: redirectionRouting,
            touchedFileDescriptors: touchedFileDescriptors,
            processSubstitutionStartIndex: processSubstitutionStartIndex,
            startedAt: startedAt,
            context: context
        ) {
            return result
        }

        switch dispatch {
        case .registryCommand:
            let xtraceStderr = context.xtraceDiagnostic(parsed)
            var result = await context.handlers.registry.executeRegistryCommand(parsed, redirectionRouting)
            result = context.handlers.registry.shellCommandLookupFailureResult(
                result,
                parsed.commandName,
                frame.sourceLineNumber
            )
            result = await finalizedResult(
                result,
                parsed: parsed,
                routing: redirectionRouting,
                processSubstitutionStartIndex: processSubstitutionStartIndex,
                commandNameForFinalize: parsed.commandName,
                context: context
            )
            result = context.withXtraceStderr(xtraceStderr, result)
            result = context.withCommandSubstitutionStderr(commandSubstitutionStderr, result)
            if frame.appliesStateChange, result.succeeded {
                context.handlers.registry.applyCommandStateChange(result.stateChange)
            }
            await recordParsedCommandAudit(
                parsed: parsed,
                fullCommandLine: fullCommandLine,
                result: result,
                startedAt: startedAt,
                context: context
            )
            return result

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
             .evalBuiltin,
             .sourceBuiltin,
             .shellLauncher,
             .structuredCompound,
             .shellFunction,
             .pathScript:
            preconditionFailure("pre-redirection, builtin, or reentry dispatch should have returned before registry")
        }
    }

}
