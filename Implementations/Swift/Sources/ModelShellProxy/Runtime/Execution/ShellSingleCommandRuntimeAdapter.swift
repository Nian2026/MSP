import Foundation
import MSPCore
import MSPShell

struct ShellRuntimeSingleCommandRunOptions {
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

struct ShellRuntimeSingleCommandPorts {
    var cleanupProcessSubstitutionTemporaryPaths: (Int) -> Void
    var makeExpansionContext: (Int32, Bool) async throws -> MSPShellExpansionContext
    var runCommandSubstitution: (
        String,
        Data,
        Bool,
        Bool,
        Int32
    ) async -> MSPShellCommandSubstitutionResult
    var resolveProcessSubstitution: (
        MSPShellProcessSubstitutionRequest,
        Data,
        Bool,
        Bool,
        Int32
    ) async throws -> MSPShellProcessSubstitutionResult
    var expansionFailureResult: (MSPShellExpansionError) -> MSPCommandResult
    var recordAudit: (String, MSPParsedCommandLine, MSPCommandResult, Date) async -> Void
    var parsedCommandsAuditLine: (MSPParsedCommandLine, String) -> String
    var redirectionFailureResult: (MSPCommandResult, Int?) -> MSPCommandResult
    var commandLookupFailureResult: (MSPCommandResult, String, Int?) -> MSPCommandResult
    var applyRedirections: (
        [MSPParsedRedirection],
        ShellExecutionFrame,
        String
    ) throws -> MSPRedirectionRouting
    var finalizeRedirections: (
        MSPRedirectionRouting,
        MSPCommandResult,
        Int,
        String?
    ) async throws -> MSPCommandResult
    var runWithScopedFileDescriptorRouting: (
        MSPRedirectionRouting,
        Set<Int>,
        @escaping () async -> MSPCommandResult
    ) async -> MSPCommandResult
    var builtinPorts: ShellRuntimeBuiltinPorts

    var appendClosedPersistentOutputProcessSubstitutions: (
        Set<String>,
        MSPCommandResult
    ) async throws -> MSPCommandResult

    var reentryPorts: ShellRuntimeReentryPorts

    var makeSubcommandRunner: () -> MSPSubcommandRunner
    var makeCommandLineRunner: () -> MSPCommandLineRunner
    var availableCommandNames: () -> [String]
    var availableCommandLookupPaths: () -> [String: [String]]
    var applyCommandStateChange: (MSPCommandRuntimeStateChange?) -> Void
}

extension ShellRuntime {
    func runSingleCommand(
        _ parsed: MSPParsedCommandLine,
        options: ShellRuntimeSingleCommandRunOptions,
        ports: ShellRuntimeSingleCommandPorts
    ) async -> MSPCommandResult {
        await ShellSingleCommandExecutor.run(
            parsed,
            fullCommandLine: options.fullCommandLine,
            context: singleCommandExecutionContext(
                frame: options.executionFrame(),
                ports: ports
            )
        )
    }

    private func singleCommandExecutionContext(
        frame: ShellExecutionFrame,
        ports: ShellRuntimeSingleCommandPorts
    ) -> ShellSingleCommandExecutionContext {
        ShellSingleCommandExecutionContext(
            frame: frame,
            processSubstitutionCheckpoint: { [self] in
                io.processSubstitutionCheckpoint
            },
            cleanupProcessSubstitutionTemporaryPaths: ports.cleanupProcessSubstitutionTemporaryPaths,
            expandCommandLine: { [self] rawParsed, frame in
                try await expandSingleCommandLine(rawParsed, frame: frame, ports: ports)
            },
            applyExpansionState: { [self] expansion in
                applyExpansionState(expansion)
            },
            expansionFailureResult: ports.expansionFailureResult,
            setPendingShellExitCode: { [self] exitCode in
                setPendingShellExitCode(exitCode)
            },
            currentDirectory: { [self] in
                configuration.currentDirectory
            },
            evaluatePolicy: { [self] request in
                await configuration.policyEngine.evaluate(request)
            },
            resolveVirtualExecutableCommandPath: { [registry, ports] commandPath in
                ShellVirtualExecutableCommandPath.commandName(
                    for: commandPath,
                    registryCommandNames: registry.commandNames,
                    commandLookupPaths: ports.availableCommandLookupPaths()
                )
            },
            commandCanRunWithPathSearch: { [self, ports] dispatch, parsed, resolvedExplicitVirtualExecutablePath in
                switch dispatch {
                case .registryCommand,
                     .shellLauncher:
                    let commandEnvironment = exportedEnvironment(applying: parsed.assignments)
                    return ShellVirtualExecutableCommandPath.commandCanRunWithPathSearch(
                        commandName: parsed.commandName,
                        resolvedExplicitVirtualExecutablePath: resolvedExplicitVirtualExecutablePath,
                        availableCommandNames: ports.availableCommandNames(),
                        commandLookupPaths: ports.availableCommandLookupPaths(),
                        environmentPath: commandEnvironment["PATH"]
                    )
                default:
                    return true
                }
            },
            dispatch: { [self] parsed in
                commandDispatch(for: parsed)
            },
            recordAudit: ports.recordAudit,
            parsedCommandsAuditLine: ports.parsedCommandsAuditLine,
            withCommandSubstitutionStderr: { stderr, result in
                ShellExecutionDiagnostics.prependingCommandSubstitutionStderr(stderr, to: result)
            },
            withXtraceStderr: { xtraceStderr, result in
                ShellExecutionDiagnostics.prependingXtraceStderr(xtraceStderr, to: result)
            },
            xtraceDiagnostic: { [self] parsed in
                xtraceDiagnostic(for: parsed)
            },
            shellRedirectionFailureResult: ports.redirectionFailureResult,
            applyRedirections: { [self] redirections, frame in
                try ports.applyRedirections(
                    redirections,
                    frame,
                    configuration.currentDirectory
                )
            },
            finalizeRedirections: ports.finalizeRedirections,
            runWithScopedFileDescriptorRouting: ports.runWithScopedFileDescriptorRouting,
            scopedOutputBinding: { [self] binding in
                io.scopedOutputBinding(binding)
            },
            handlers: singleCommandHandlers(frame: frame, ports: ports)
        )
    }

    private func expandSingleCommandLine(
        _ rawParsed: MSPParsedCommandLine,
        frame: ShellExecutionFrame,
        ports: ShellRuntimeSingleCommandPorts
    ) async throws -> MSPShellCommandSubstitutionExpansion {
        try await rawParsed.expandedResolvingCommandSubstitutions(
            in: try await ports.makeExpansionContext(
                frame.lastExitCode,
                rawParsed.mspMayNeedPathnameExpansionCandidates(
                    enablesExtendedGlob: shellOptionEnabled("extglob")
                )
            ),
            resolver: { commandLine in
                await ports.runCommandSubstitution(
                    commandLine,
                    frame.standardInput,
                    frame.standardInputClosed,
                    frame.standardInputOverridesFileDescriptor,
                    frame.lastExitCode
                )
            },
            processSubstitutionResolver: { request in
                try await ports.resolveProcessSubstitution(
                    request,
                    frame.standardInput,
                    frame.standardInputClosed,
                    frame.standardInputOverridesFileDescriptor,
                    frame.lastExitCode
                )
            }
        )
    }

    private func singleCommandHandlers(
        frame: ShellExecutionFrame,
        ports: ShellRuntimeSingleCommandPorts
    ) -> ShellSingleCommandHandlers {
        ShellSingleCommandHandlers(
            preRedirection: singleCommandPreRedirectionHandlers(ports: ports),
            builtins: singleCommandBuiltinHandlers(ports: ports),
            reentry: singleCommandReentryHandlers(ports: ports),
            registry: singleCommandRegistryHandlers(frame: frame, ports: ports)
        )
    }

    private func singleCommandPreRedirectionHandlers(
        ports: ShellRuntimeSingleCommandPorts
    ) -> ShellSingleCommandPreRedirectionHandlers {
        ShellSingleCommandPreRedirectionHandlers(
            storeFunctionDefinition: { [self] functionDefinition, appliesStateChange in
                guard appliesStateChange else {
                    return
                }
                storeFunctionDefinition(
                    functionDefinition,
                    sourceName: shellFunctionSourceNameForCurrentDefinition()
                )
            },
            persistentOutputProcessSubstitutionPaths: { [self] in
                io.persistentOutputProcessSubstitutionPaths
            },
            executeExecCommand: { [self] arguments, redirections, appliesStateChange in
                executeExecCommand(
                    arguments: arguments,
                    redirections: redirections,
                    appliesStateChange: appliesStateChange,
                    ports: ports.builtinPorts
                )
            },
            appendClosedPersistentOutputProcessSubstitutions:
                ports.appendClosedPersistentOutputProcessSubstitutions
        )
    }

    private func singleCommandBuiltinHandlers(
        ports: ShellRuntimeSingleCommandPorts
    ) -> ShellSingleCommandBuiltinHandlers {
        ShellSingleCommandBuiltinHandlers(
            executeReturnCommand: { [self] arguments, lastExitCode in
                executeReturnCommand(arguments: arguments, lastExitCode: lastExitCode)
            },
            executeLoopControlCommand: { [self] name, arguments, appliesStateChange in
                executeLoopControlCommand(
                    name: name,
                    arguments: arguments,
                    appliesStateChange: appliesStateChange
                )
            },
            executeExitCommand: { [self] arguments, lastExitCode, appliesStateChange in
                executeExitCommand(
                    arguments: arguments,
                    lastExitCode: lastExitCode,
                    appliesStateChange: appliesStateChange
                )
            },
            executeShiftCommand: { [self] arguments, appliesStateChange in
                executeShiftCommand(arguments: arguments, appliesStateChange: appliesStateChange)
            },
            executeSetCommand: { [self] arguments, appliesStateChange in
                executeSetCommand(arguments: arguments, appliesStateChange: appliesStateChange)
            },
            executeShoptCommand: { [self] arguments, appliesStateChange in
                executeShoptCommand(arguments: arguments, appliesStateChange: appliesStateChange)
            },
            executeDeclareCommand: { [self] commandName, arguments, appliesStateChange in
                executeDeclareCommand(
                    commandName: commandName,
                    arguments: arguments,
                    appliesStateChange: appliesStateChange
                )
            },
            executeVariableAttributeCommand: { [self] commandName, arguments, appliesStateChange in
                executeVariableAttributeCommand(
                    commandName: commandName,
                    arguments: arguments,
                    appliesStateChange: appliesStateChange
                )
            },
            executeAliasCommand: { [self] commandName, arguments, appliesStateChange in
                commandName == "alias"
                    ? executeAliasCommand(arguments: arguments, appliesStateChange: appliesStateChange)
                    : executeUnaliasCommand(arguments: arguments, appliesStateChange: appliesStateChange)
            },
            executeTrapCommand: { [self] arguments, appliesStateChange in
                executeTrapCommand(arguments: arguments, appliesStateChange: appliesStateChange)
            },
            executeUmaskCommand: { [self] arguments, appliesStateChange in
                executeUmaskCommand(arguments: arguments, appliesStateChange: appliesStateChange)
            },
            executeUnsetCommand: { [self] arguments, appliesStateChange in
                executeUnsetCommand(arguments: arguments, appliesStateChange: appliesStateChange)
            },
            executeLocalCommand: { [self] arguments, appliesStateChange in
                executeLocalCommand(arguments: arguments, appliesStateChange: appliesStateChange)
            },
            executeReadCommand: { [self] arguments, routing, assignments, appliesStateChange in
                await executeReadCommand(
                    arguments: arguments,
                    routing: routing,
                    assignments: assignments,
                    appliesStateChange: appliesStateChange,
                    ports: ports.builtinPorts
                )
            },
            executeMapfileCommand: { [self] commandName, arguments, routing, appliesStateChange in
                await executeMapfileCommand(
                    commandName: commandName,
                    arguments: arguments,
                    routing: routing,
                    appliesStateChange: appliesStateChange,
                    ports: ports.builtinPorts
                )
            },
            executeArithmeticCommand: { [self] arithmeticExpression, appliesStateChange in
                do {
                    let evaluation = try evaluateArithmeticCommand(
                        arithmeticExpression,
                        appliesStateChange: appliesStateChange
                    )
                    return MSPCommandResult(exitCode: evaluation.exitCode)
                } catch let expansionError as MSPShellExpansionError {
                    return .failure(exitCode: 1, stderr: "\(expansionError)\n")
                } catch {
                    return .failure(exitCode: 1, stderr: "arithmetic expansion: \(error)\n")
                }
            },
            applyAssignmentOnlyStateChange: { [self] parsed in
                applyAssignmentOnlyStateChange(parsed)
            },
            executeDoubleBracketRegexCommand: { [self] arguments, appliesStateChange in
                executeDoubleBracketRegexCommand(
                    arguments: arguments,
                    appliesStateChange: appliesStateChange
                )
            }
        )
    }

    private func singleCommandReentryHandlers(
        ports: ShellRuntimeSingleCommandPorts
    ) -> ShellSingleCommandReentryHandlers {
        ShellSingleCommandReentryHandlers(
            executeEvalCommand: { [self] request in
                await executeEvalCommand(request, ports: ports.reentryPorts)
            },
            executeSourceCommand: { [self] request in
                await executeSourceCommand(request, ports: ports.reentryPorts)
            },
            executeShellLauncherCommand: { [self] request in
                await executeShellLauncherCommand(request, ports: ports.reentryPorts)
            },
            runCompoundCommand: { [self] request in
                await runCompoundCommand(request, ports: ports.reentryPorts)
            },
            saveShellRuntimeState: { [self] in
                captureState()
            },
            restoreShellRuntimeState: { [self] state in
                restoreState(state)
            },
            executeShellFunction: { [self] request in
                await executeShellFunction(request, ports: ports.reentryPorts)
            },
            executePathScriptCommand: { [self] request in
                await executePathScriptCommand(request, ports: ports.reentryPorts)
            }
        )
    }

    private func singleCommandRegistryHandlers(
        frame: ShellExecutionFrame,
        ports: ShellRuntimeSingleCommandPorts
    ) -> ShellSingleCommandRegistryHandlers {
        ShellSingleCommandRegistryHandlers(
            executeRegistryCommand: { [self] parsed, routing in
                let invocation = MSPCommandInvocation(
                    name: parsed.commandName,
                    arguments: parsed.arguments,
                    rawInput: parsed.rawInput
                )
                var commandConfiguration = configuration
                commandConfiguration.environment = exportedEnvironment(applying: parsed.assignments)
                let visibleStreams = ShellOutputForwarding.visibleStreams(
                    stdoutBinding: routing.stdoutBinding,
                    stderrBinding: routing.stderrBinding,
                    outputStream: frame.outputStream,
                    errorStream: frame.errorStream
                )
                let inheritsStandardInputStream = !frame.standardInputOverridesFileDescriptor
                    && !routing.standardInputClosed
                    && routing.standardInputDescriptor == nil
                    && !IORuntimeState.redirectionsScopeStandardInput(parsed.redirections)
                let context = commandConfiguration.makeCommandContext(
                    standardInput: routing.standardInput,
                    standardInputClosed: routing.standardInputClosed,
                    standardInputStream: inheritsStandardInputStream
                        ? commandConfiguration.standardInputStream
                        : nil,
                    standardOutputStream: visibleStreams.outputStream,
                    standardErrorStream: visibleStreams.errorStream,
                    availableCommandNames: ports.availableCommandNames(),
                    commandLookupPaths: ports.availableCommandLookupPaths(),
                    subcommandRunner: ports.makeSubcommandRunner(),
                    commandLineRunner: ports.makeCommandLineRunner()
                )
                return await MSPCommandExecutor(registry: registry)
                    .run(invocation: invocation, context: context)
            },
            shellCommandLookupFailureResult: ports.commandLookupFailureResult,
            applyCommandStateChange: ports.applyCommandStateChange
        )
    }

    private func shellFunctionSourceNameForCurrentDefinition() -> String? {
        shellDiagnostics(
            configuredContext: ShellExecutionDiagnostics.configuredContext(
                for: configuration.shellDiagnosticProfile
            )
        )
        .functionSourceNameForCurrentDefinition
    }
}

private extension ShellRuntimeSingleCommandRunOptions {
    func executionFrame() -> ShellExecutionFrame {
        ShellExecutionFrame(
            standardInput: standardInput,
            standardInputClosed: standardInputClosed,
            standardInputOverridesFileDescriptor: standardInputOverridesFileDescriptor,
            stdoutBindingOverride: stdoutBindingOverride,
            stderrBindingOverride: stderrBindingOverride,
            appliesStateChange: appliesStateChange,
            lastExitCode: lastExitCode,
            sourceLineNumber: sourceLineNumber,
            outputStream: outputStream,
            errorStream: errorStream
        )
    }
}
