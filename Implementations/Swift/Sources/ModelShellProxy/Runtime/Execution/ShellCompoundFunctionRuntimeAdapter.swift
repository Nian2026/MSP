import Foundation
import MSPCore
import MSPShell

extension ShellRuntime {
    private static let compoundLoopIterationLimit = 10_000
    private static let shellFunctionDepthLimit = 128

    func runCompoundCommand(
        _ request: ShellSingleCommandCompoundRequest,
        ports: ShellRuntimeReentryPorts
    ) async -> MSPCommandResult {
        await compoundFunctionRuntime(ports: ports).runCompoundCommand(request)
    }

    func executeShellFunction(
        _ request: ShellSingleCommandFunctionRequest,
        ports: ShellRuntimeReentryPorts
    ) async -> MSPCommandResult {
        await compoundFunctionRuntime(ports: ports).executeShellFunction(request)
    }

    private func compoundFunctionRuntime(
        ports: ShellRuntimeReentryPorts
    ) -> ShellCompoundFunctionRuntime {
        ShellCompoundFunctionRuntime(
            context: ShellCompoundFunctionRuntimeContext(
                compoundLoopIterationLimit: Self.compoundLoopIterationLimit,
                shellFunctionDepthLimit: Self.shellFunctionDepthLimit,
                configuration: { [self] in configuration },
                setConfiguration: { [self] configuration in self.configuration = configuration },
                captureState: { [self] in captureState() },
                restoreState: { [self] state in restoreState(state) },
                runCommandList: ports.commands.runCommandList,
                runCommandText: ports.commands.runCommandText,
                withScopedOutputBindings: { [self] stdoutBinding, stderrBinding, operation in
                    await runWithScopedOutputBindings(
                        stdoutBinding: stdoutBinding,
                        stderrBinding: stderrBinding
                    ) {
                        await operation()
                    }
                },
                visibleOutputStreams: { [self] outputStream, errorStream in
                    visibleOutputStreams(outputStream: outputStream, errorStream: errorStream)
                },
                functionDepth: { [self] in functionDepthValue() },
                setFunctionDepth: { [self] value in setFunctionDepth(value) },
                positionalParameters: { [self] in positionalParametersValue() },
                setPositionalParameters: { [self] value in setPositionalParameters(value) },
                loopDepth: { [self] in loopDepthValue() },
                setLoopDepth: { [self] value in setLoopDepth(value) },
                pendingFunctionReturnCode: { [self] in pendingFunctionReturnCodeValue() },
                setPendingFunctionReturnCode: { [self] value in setPendingFunctionReturnCode(value) },
                pendingLoopControl: { [self] in pendingLoopControlValue() },
                setPendingLoopControl: { [self] value in setPendingLoopControl(value) },
                pendingShellExitCode: { [self] in pendingShellExitCodeValue() },
                pushFunctionLocalEnvironmentFrame: { [self] in
                    pushFunctionLocalEnvironmentFrame()
                },
                restoreFunctionLocalEnvironmentFrame: { [self] in
                    restoreFunctionLocalEnvironmentFrame()
                },
                popFunctionLocalEnvironmentFrame: { [self] in
                    popFunctionLocalEnvironmentFrame()
                },
                currentDiagnosticContext: { [self] in
                    currentDiagnosticContext(
                        configuredContext: ShellExecutionDiagnostics.configuredContext(
                            for: configuration.shellDiagnosticProfile
                        )
                    )
                },
                pushDiagnosticContext: { [self] context in
                    pushDiagnosticContext(context)
                },
                popDiagnosticContext: { [self] in
                    popDiagnosticContext()
                },
                savedEnvironmentValues: { [self] names in
                    savedEnvironmentValues(for: names)
                },
                restoreEnvironmentValues: { [self] values, preservedNames in
                    restoreEnvironmentValues(values, preserving: preservedNames)
                },
                environmentApplyingAssignments: { [self] base, assignments in
                    environment(base, applying: assignments)
                },
                setEnvironmentValue: { [self] name, value in
                    setEnvironmentValue(name, value)
                },
                processSubstitutionCheckpoint: { [self] in
                    io.processSubstitutionCheckpoint
                },
                applyRedirections: ports.io.applyRedirections,
                finalizeRedirections: ports.io.finalizeRedirections,
                runWithScopedFileDescriptorRouting: { [self] routing, touchedFileDescriptors, operation in
                    await runWithScopedFileDescriptorRouting(
                        routing,
                        touchedFileDescriptors: touchedFileDescriptors
                    ) {
                        await operation()
                    }
                },
                scopedOutputBinding: { [self] binding in
                    io.scopedOutputBinding(binding)
                },
                persistentInputFileDescriptor: { [self] fd in
                    io.persistentInputFileDescriptors[fd]
                },
                remainingInputData: ports.io.remainingInputData,
                consumeInputOpenFileDescription: { [self] descriptionID, byteCount in
                    io.consumeInputOpenFileDescription(id: descriptionID, byteCount: byteCount)
                },
                expandedReadAssignmentEnvironment: ports.expansion.expandedReadAssignmentEnvironment,
                assignReadRecord: { [self] record, names in
                    assignReadRecord(record, to: names)
                },
                expandWordText: ports.expansion.expandWordText,
                expandWordVariants: ports.expansion.expandWordVariants,
                evaluateArithmetic: { [self] expression in
                    try evaluateArithmeticCommand(expression)
                }
            )
        )
    }
}
