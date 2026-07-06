extension ShellRuntime {
    func captureState() -> ShellRuntimeState {
        ShellRuntimeState(
            configuration: configuration,
            shellFunctions: state.shellFunctions,
            shellFunctionSourceNames: state.shellFunctionSourceNames,
            functionDepth: state.functionDepth,
            loopDepth: state.loopDepth,
            functionLocalEnvironmentStack: state.functionLocalEnvironmentStack,
            sourceDepth: state.sourceDepth,
            positionalParameters: state.positionalParameters,
            pendingFunctionReturnCode: state.pendingFunctionReturnCode,
            pendingLoopControl: state.pendingLoopControl,
            pendingShellExitCode: state.pendingShellExitCode,
            io: io,
            shellOptions: state.shellOptions,
            shellArrays: state.shellArrays,
            shellAssociativeArrays: state.shellAssociativeArrays,
            shellNamerefs: state.shellNamerefs,
            shellAliases: state.shellAliases,
            exportedVariableNames: state.exportedVariableNames,
            readonlyVariableNames: state.readonlyVariableNames,
            shellTraps: state.shellTraps,
            runningTraps: state.runningTraps,
            isErrexitEnabled: state.isErrexitEnabled,
            isNounsetEnabled: state.isNounsetEnabled,
            isPipefailEnabled: state.isPipefailEnabled,
            isXtraceEnabled: state.isXtraceEnabled,
            enablesBashParameterExtensions: state.enablesBashParameterExtensions,
            shellDiagnosticContextStack: state.shellDiagnosticContextStack
        )
    }

    func restoreState(_ snapshot: ShellRuntimeState) {
        configuration = snapshot.configuration
        state.shellFunctions = snapshot.shellFunctions
        state.shellFunctionSourceNames = snapshot.shellFunctionSourceNames
        state.functionDepth = snapshot.functionDepth
        state.loopDepth = snapshot.loopDepth
        state.functionLocalEnvironmentStack = snapshot.functionLocalEnvironmentStack
        state.sourceDepth = snapshot.sourceDepth
        state.positionalParameters = snapshot.positionalParameters
        state.pendingFunctionReturnCode = snapshot.pendingFunctionReturnCode
        state.pendingLoopControl = snapshot.pendingLoopControl
        state.pendingShellExitCode = snapshot.pendingShellExitCode
        io = snapshot.io
        state.shellOptions = snapshot.shellOptions
        state.shellArrays = snapshot.shellArrays
        state.shellAssociativeArrays = snapshot.shellAssociativeArrays
        state.shellNamerefs = snapshot.shellNamerefs
        state.shellAliases = snapshot.shellAliases
        state.exportedVariableNames = snapshot.exportedVariableNames
        state.readonlyVariableNames = snapshot.readonlyVariableNames
        state.shellTraps = snapshot.shellTraps
        state.runningTraps = snapshot.runningTraps
        state.isErrexitEnabled = snapshot.isErrexitEnabled
        state.isNounsetEnabled = snapshot.isNounsetEnabled
        state.isPipefailEnabled = snapshot.isPipefailEnabled
        state.isXtraceEnabled = snapshot.isXtraceEnabled
        state.enablesBashParameterExtensions = snapshot.enablesBashParameterExtensions
        state.shellDiagnosticContextStack = snapshot.shellDiagnosticContextStack
    }

    func runtimeBuiltinContext() -> RuntimeBuiltinContext {
        RuntimeBuiltinContext(
            configuration: configuration,
            shellFunctions: state.shellFunctions,
            shellFunctionSourceNames: state.shellFunctionSourceNames,
            functionDepth: state.functionDepth,
            sourceDepth: state.sourceDepth,
            loopDepth: state.loopDepth,
            functionLocalEnvironmentStack: state.functionLocalEnvironmentStack,
            positionalParameters: state.positionalParameters,
            pendingFunctionReturnCode: state.pendingFunctionReturnCode,
            pendingLoopControl: state.pendingLoopControl,
            pendingShellExitCode: state.pendingShellExitCode,
            shellOptions: state.shellOptions,
            shellArrays: state.shellArrays,
            shellAssociativeArrays: state.shellAssociativeArrays,
            shellNamerefs: state.shellNamerefs,
            shellAliases: state.shellAliases,
            shellDiagnosticContextStack: state.shellDiagnosticContextStack,
            exportedVariableNames: state.exportedVariableNames,
            readonlyVariableNames: state.readonlyVariableNames,
            shellTraps: state.shellTraps,
            isErrexitEnabled: state.isErrexitEnabled,
            isNounsetEnabled: state.isNounsetEnabled,
            isPipefailEnabled: state.isPipefailEnabled,
            isXtraceEnabled: state.isXtraceEnabled,
            enablesBashParameterExtensions: state.enablesBashParameterExtensions
        )
    }

    func applyRuntimeBuiltinContext(_ context: RuntimeBuiltinContext) {
        configuration = context.configuration
        state.shellFunctions = context.shellFunctions
        state.shellFunctionSourceNames = context.shellFunctionSourceNames
        state.functionDepth = context.functionDepth
        state.sourceDepth = context.sourceDepth
        state.loopDepth = context.loopDepth
        state.functionLocalEnvironmentStack = context.functionLocalEnvironmentStack
        state.positionalParameters = context.positionalParameters
        state.pendingFunctionReturnCode = context.pendingFunctionReturnCode
        state.pendingLoopControl = context.pendingLoopControl
        state.pendingShellExitCode = context.pendingShellExitCode
        state.shellOptions = context.shellOptions
        state.shellArrays = context.shellArrays
        state.shellAssociativeArrays = context.shellAssociativeArrays
        state.shellNamerefs = context.shellNamerefs
        state.shellAliases = context.shellAliases
        state.shellDiagnosticContextStack = context.shellDiagnosticContextStack
        state.exportedVariableNames = context.exportedVariableNames
        state.readonlyVariableNames = context.readonlyVariableNames
        state.shellTraps = context.shellTraps
        state.isErrexitEnabled = context.isErrexitEnabled
        state.isNounsetEnabled = context.isNounsetEnabled
        state.isPipefailEnabled = context.isPipefailEnabled
        state.isXtraceEnabled = context.isXtraceEnabled
        state.enablesBashParameterExtensions = context.enablesBashParameterExtensions
    }
}
