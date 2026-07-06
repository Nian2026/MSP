import Foundation
import MSPCore
import MSPShell

struct ShellCompoundCommandListRunRequest {
    var commandList: MSPParsedCommandList
    var initialLastExitCode: Int32
    var sourceLineOffset: Int
    var suppressesErrexit: Bool
    var outputStream: (any MSPCommandOutputStream)?
    var errorStream: (any MSPCommandOutputStream)?
}

struct ShellCompoundCommandTextRunRequest {
    var commandText: String
    var initialLastExitCode: Int32
    var sourceLineOffset: Int
    var suppressesErrexit: Bool
    var outputStream: (any MSPCommandOutputStream)?
    var errorStream: (any MSPCommandOutputStream)?
}

struct ShellCompoundFunctionRuntimeContext {
    var compoundLoopIterationLimit: Int
    var shellFunctionDepthLimit: Int

    var configuration: () -> MSPConfiguration
    var setConfiguration: (MSPConfiguration) -> Void
    var captureState: () -> ShellRuntimeState
    var restoreState: (ShellRuntimeState) -> Void

    var runCommandList: (ShellCompoundCommandListRunRequest) async -> MSPCommandResult
    var runCommandText: (ShellCompoundCommandTextRunRequest) async -> MSPCommandResult
    var withScopedOutputBindings: (
        MSPRedirectionOutputBinding?,
        MSPRedirectionOutputBinding?,
        @escaping () async -> MSPCommandResult
    ) async -> MSPCommandResult
    var visibleOutputStreams: (
        (any MSPCommandOutputStream)?,
        (any MSPCommandOutputStream)?
    ) -> (
        outputStream: (any MSPCommandOutputStream)?,
        errorStream: (any MSPCommandOutputStream)?
    )

    var functionDepth: () -> Int
    var setFunctionDepth: (Int) -> Void
    var positionalParameters: () -> [String]
    var setPositionalParameters: ([String]) -> Void
    var loopDepth: () -> Int
    var setLoopDepth: (Int) -> Void
    var pendingFunctionReturnCode: () -> Int32?
    var setPendingFunctionReturnCode: (Int32?) -> Void
    var pendingLoopControl: () -> MSPShellLoopControl?
    var setPendingLoopControl: (MSPShellLoopControl?) -> Void
    var pendingShellExitCode: () -> Int32?

    var pushFunctionLocalEnvironmentFrame: () -> Void
    var restoreFunctionLocalEnvironmentFrame: () -> Void
    var popFunctionLocalEnvironmentFrame: () -> Void
    var currentDiagnosticContext: () -> MSPShellDiagnosticContext?
    var pushDiagnosticContext: (MSPShellDiagnosticContext) -> Void
    var popDiagnosticContext: () -> Void

    var savedEnvironmentValues: ([String]) -> [String: String?]
    var restoreEnvironmentValues: ([String: String?], Set<String>) -> Void
    var environmentApplyingAssignments: ([String: String], [MSPParsedAssignment]) -> [String: String]
    var setEnvironmentValue: (String, String) -> Void

    var processSubstitutionCheckpoint: () -> Int
    var applyRedirections: (
        [MSPParsedRedirection],
        Data,
        Bool,
        String,
        MSPRedirectionOutputBinding?,
        MSPRedirectionOutputBinding?
    ) throws -> MSPRedirectionRouting
    var finalizeRedirections: (
        MSPRedirectionRouting,
        MSPCommandResult,
        Int
    ) async throws -> MSPCommandResult
    var runWithScopedFileDescriptorRouting: (
        MSPRedirectionRouting,
        Set<Int>,
        @escaping () async -> MSPCommandResult
    ) async -> MSPCommandResult
    var scopedOutputBinding: (MSPRedirectionOutputBinding) -> MSPRedirectionOutputBinding

    var persistentInputFileDescriptor: (Int) -> Int?
    var remainingInputData: (Int) throws -> Data
    var consumeInputOpenFileDescription: (Int, Int) -> Void
    var expandedReadAssignmentEnvironment: (
        MSPParsedReadSpec,
        Int32,
        inout String
    ) async throws -> [MSPParsedAssignment]
    var assignReadRecord: (String, [String]) -> Void

    var expandWordText: (
        MSPParsedWord,
        Int32,
        Bool,
        Bool
    ) async throws -> MSPShellWordTextExpansionResult
    var expandWordVariants: (
        MSPParsedWord,
        Int32
    ) async throws -> MSPShellWordExpansionResult
    var evaluateArithmetic: (String) throws -> MSPShellArithmeticCommandEvaluation
}

struct ShellCompoundFunctionRuntime {
    var context: ShellCompoundFunctionRuntimeContext

    func runCompoundCommand(
        _ request: ShellSingleCommandCompoundRequest
    ) async -> MSPCommandResult {
        let restoresFullState = !request.appliesStateChange
            || !Self.compoundCommandPersistsStateInParent(request.compoundCommand)
        let previousState = restoresFullState ? context.captureState() : nil
        let previousConfiguration = context.configuration()
        var childConfiguration = previousConfiguration
        childConfiguration.standardInput = request.io.standardInput
        childConfiguration.standardInputClosed = request.io.standardInputClosed
        context.setConfiguration(childConfiguration)

        let result = await context.withScopedOutputBindings(
            request.io.stdoutBinding,
            request.io.stderrBinding
        ) {
            let streams = context.visibleOutputStreams(
                request.io.outputStream,
                request.io.errorStream
            )
            return await executeCompoundCommand(
                request.compoundCommand,
                lastExitCode: request.io.lastExitCode,
                sourceLineNumber: request.sourceLineNumber,
                outputStream: streams.outputStream,
                errorStream: streams.errorStream
            )
        }

        if let previousState {
            context.restoreState(previousState)
        } else {
            var persistedConfiguration = context.configuration()
            persistedConfiguration.standardInput = previousConfiguration.standardInput
            persistedConfiguration.standardInputClosed = previousConfiguration.standardInputClosed
            context.setConfiguration(persistedConfiguration)
        }
        return result
    }

    func executeShellFunction(
        _ request: ShellSingleCommandFunctionRequest
    ) async -> MSPCommandResult {
        let definition = request.functionDefinition
        guard context.functionDepth() < context.shellFunctionDepthLimit else {
            return .failure(exitCode: 124, stderr: "shell: maximum function depth exceeded\n")
        }

        let previousPositionalParameters = context.positionalParameters()
        let previousConfiguration = context.configuration()
        let assignmentPreviousValues = context.savedEnvironmentValues(request.assignments.map(\.name))
        let processSubstitutionStartIndex = context.processSubstitutionCheckpoint()
        var functionConfiguration = previousConfiguration
        functionConfiguration.environment = context.environmentApplyingAssignments(
            functionConfiguration.environment,
            request.assignments
        )
        functionConfiguration.standardInput = request.io.standardInput
        functionConfiguration.standardInputClosed = request.io.standardInputClosed
        context.setConfiguration(functionConfiguration)
        context.setPositionalParameters([definition.name] + request.arguments)
        context.setFunctionDepth(context.functionDepth() + 1)
        context.pushFunctionLocalEnvironmentFrame()
        if let diagnosticSourceName = request.diagnosticSourceName,
           let currentDiagnosticContext = context.currentDiagnosticContext() {
            context.pushDiagnosticContext(
                MSPShellDiagnosticContext(
                    scriptName: diagnosticSourceName,
                    style: currentDiagnosticContext.style
                )
            )
        }

        defer {
            if request.diagnosticSourceName != nil, context.currentDiagnosticContext() != nil {
                context.popDiagnosticContext()
            }
            context.restoreFunctionLocalEnvironmentFrame()
            context.setFunctionDepth(context.functionDepth() - 1)
            context.popFunctionLocalEnvironmentFrame()
            context.setPositionalParameters(previousPositionalParameters)
            var restoredConfiguration = context.configuration()
            restoredConfiguration.standardInput = previousConfiguration.standardInput
            restoredConfiguration.standardInputClosed = previousConfiguration.standardInputClosed
            context.setConfiguration(restoredConfiguration)
            context.restoreEnvironmentValues(assignmentPreviousValues, [])
        }

        let definitionRouting: MSPRedirectionRouting
        do {
            definitionRouting = try context.applyRedirections(
                definition.redirections,
                request.io.standardInput,
                request.io.standardInputClosed,
                context.configuration().currentDirectory,
                request.io.stdoutBinding,
                request.io.stderrBinding
            )
        } catch let failure as MSPCommandFailure {
            return failure.result
        } catch {
            return .failure(exitCode: 1, stderr: "\(definition.name): \(error)\n")
        }

        let result: MSPCommandResult
        let definitionOutputScope = IORuntimeState.redirectionOutputScope(
            for: definition.redirections,
            stdoutBindingOverride: request.io.stdoutBinding,
            stderrBindingOverride: request.io.stderrBinding
        )
        let definitionTouchedFileDescriptors = IORuntimeState.redirectionTouchedFileDescriptors(definition.redirections)
        switch definition.bodyKind {
        case .braceGroup:
            let previousBodyStandardInput = context.configuration().standardInput
            let previousBodyStandardInputClosed = context.configuration().standardInputClosed
            updateConfiguration { configuration in
                configuration.standardInput = definitionRouting.standardInput
                configuration.standardInputClosed = definitionRouting.standardInputClosed
            }
            if let structuredBody = definition.structuredBody {
                result = await context.runWithScopedFileDescriptorRouting(
                    definitionRouting,
                    definitionTouchedFileDescriptors
                ) {
                    await context.withScopedOutputBindings(
                        definitionOutputScope.stdout
                            ? context.scopedOutputBinding(definitionRouting.stdoutBinding)
                            : nil,
                        definitionOutputScope.stderr
                            ? context.scopedOutputBinding(definitionRouting.stderrBinding)
                            : nil
                    ) {
                        let streams = context.visibleOutputStreams(
                            request.io.outputStream,
                            request.io.errorStream
                        )
                        return await runCommandList(
                            structuredBody,
                            initialLastExitCode: request.io.lastExitCode,
                            outputStream: streams.outputStream,
                            errorStream: streams.errorStream
                        )
                    }
                }
            } else {
                result = await context.runWithScopedFileDescriptorRouting(
                    definitionRouting,
                    definitionTouchedFileDescriptors
                ) {
                    await context.withScopedOutputBindings(
                        definitionOutputScope.stdout
                            ? context.scopedOutputBinding(definitionRouting.stdoutBinding)
                            : nil,
                        definitionOutputScope.stderr
                            ? context.scopedOutputBinding(definitionRouting.stderrBinding)
                            : nil
                    ) {
                        let streams = context.visibleOutputStreams(
                            request.io.outputStream,
                            request.io.errorStream
                        )
                        return await runCommandText(
                            definition.body,
                            initialLastExitCode: request.io.lastExitCode,
                            outputStream: streams.outputStream,
                            errorStream: streams.errorStream
                        )
                    }
                }
            }
            updateConfiguration { configuration in
                configuration.standardInput = previousBodyStandardInput
                configuration.standardInputClosed = previousBodyStandardInputClosed
            }
        case .subshell:
            if let structuredBody = definition.structuredBody {
                result = await context.runWithScopedFileDescriptorRouting(
                    definitionRouting,
                    definitionTouchedFileDescriptors
                ) {
                    await runCompoundCommand(
                        ShellSingleCommandCompoundRequest(
                            compoundCommand: .subshell(body: structuredBody),
                            io: ShellSingleCommandReentryIO(
                                standardInput: definitionRouting.standardInput,
                                standardInputClosed: definitionRouting.standardInputClosed,
                                stdoutBinding: definitionOutputScope.stdout
                                    ? context.scopedOutputBinding(definitionRouting.stdoutBinding)
                                    : nil,
                                stderrBinding: definitionOutputScope.stderr
                                    ? context.scopedOutputBinding(definitionRouting.stderrBinding)
                                    : nil,
                                lastExitCode: request.io.lastExitCode,
                                outputStream: request.io.outputStream,
                                errorStream: request.io.errorStream
                            ),
                            appliesStateChange: true,
                            sourceLineNumber: nil
                        )
                    )
                }
            } else {
                result = await context.runWithScopedFileDescriptorRouting(
                    definitionRouting,
                    definitionTouchedFileDescriptors
                ) {
                    await runLegacyFunctionSubshellBody(
                        definition.body,
                        routing: definitionRouting,
                        outputScope: definitionOutputScope,
                        request: request
                    )
                }
            }
        }

        var functionResult = result
        if let returnCode = context.pendingFunctionReturnCode() {
            context.setPendingFunctionReturnCode(nil)
            functionResult.exitCode = returnCode
        }
        do {
            return try await context.finalizeRedirections(
                definitionRouting,
                functionResult,
                processSubstitutionStartIndex
            )
        } catch let failure as MSPCommandFailure {
            return failure.result
        } catch {
            return .failure(exitCode: 1, stderr: "\(definition.name): \(error)\n")
        }
    }

    private func runLegacyFunctionSubshellBody(
        _ body: String,
        routing: MSPRedirectionRouting,
        outputScope: MSPRedirectionOutputScope,
        request: ShellSingleCommandFunctionRequest
    ) async -> MSPCommandResult {
        let previousState = context.captureState()
        updateConfiguration { configuration in
            configuration.standardInput = routing.standardInput
            configuration.standardInputClosed = routing.standardInputClosed
        }

        let result = await context.withScopedOutputBindings(
            outputScope.stdout
                ? context.scopedOutputBinding(routing.stdoutBinding)
                : nil,
            outputScope.stderr
                ? context.scopedOutputBinding(routing.stderrBinding)
                : nil
        ) {
            let streams = context.visibleOutputStreams(
                request.io.outputStream,
                request.io.errorStream
            )
            return await runCommandText(
                body,
                initialLastExitCode: request.io.lastExitCode,
                outputStream: streams.outputStream,
                errorStream: streams.errorStream
            )
        }

        context.restoreState(previousState)
        return result
    }

    private static func compoundCommandPersistsStateInParent(
        _ compoundCommand: MSPParsedStructuredCompoundCommand
    ) -> Bool {
        switch compoundCommand {
        case .subshell:
            return false
        case .group,
             .ifThen,
             .whileLoop,
             .untilLoop,
             .whileRead,
             .forEach,
             .cStyleFor,
             .caseOf:
            return true
        }
    }

    private func executeCompoundCommand(
        _ compoundCommand: MSPParsedStructuredCompoundCommand,
        lastExitCode: Int32,
        sourceLineNumber: Int?,
        outputStream: (any MSPCommandOutputStream)?,
        errorStream: (any MSPCommandOutputStream)?
    ) async -> MSPCommandResult {
        switch compoundCommand {
        case .group(let body), .subshell(let body):
            return await runCommandList(
                body,
                initialLastExitCode: lastExitCode,
                sourceLineOffset: sourceLineNumber.map { max(0, $0 - 1) } ?? 0,
                outputStream: outputStream,
                errorStream: errorStream
            )
        case .ifThen(let branches, let elseBody):
            return await executeIfCommand(
                branches: branches,
                elseBody: elseBody,
                lastExitCode: lastExitCode,
                outputStream: outputStream,
                errorStream: errorStream
            )
        case .whileLoop(let condition, let body):
            return await executeConditionalLoop(
                condition: condition,
                body: body,
                loopName: "while",
                lastExitCode: lastExitCode,
                outputStream: outputStream,
                errorStream: errorStream,
                shouldRunForConditionExitCode: { $0 == 0 }
            )
        case .untilLoop(let condition, let body):
            return await executeConditionalLoop(
                condition: condition,
                body: body,
                loopName: "until",
                lastExitCode: lastExitCode,
                outputStream: outputStream,
                errorStream: errorStream,
                shouldRunForConditionExitCode: { $0 != 0 }
            )
        case .whileRead(let spec, let body):
            return await executeWhileRead(
                spec: spec,
                body: body,
                lastExitCode: lastExitCode,
                outputStream: outputStream,
                errorStream: errorStream
            )
        case .forEach(let variable, let values, let body):
            return await executeForEach(
                variable: variable,
                values: values,
                body: body,
                lastExitCode: lastExitCode,
                outputStream: outputStream,
                errorStream: errorStream
            )
        case .cStyleFor(let header, let body):
            return await executeCStyleFor(
                header: header,
                body: body,
                lastExitCode: lastExitCode,
                outputStream: outputStream,
                errorStream: errorStream
            )
        case .caseOf(let subject, let arms):
            return await executeCase(
                subject: subject,
                arms: arms,
                lastExitCode: lastExitCode,
                outputStream: outputStream,
                errorStream: errorStream
            )
        }
    }
}
