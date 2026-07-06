import MSPCore
import MSPShell

extension ShellRuntime {
    var hasPendingShellControl: Bool {
        state.pendingFunctionReturnCode != nil
            || state.pendingLoopControl != nil
            || state.pendingShellExitCode != nil
    }

    var shellOptionsSnapshot: Set<String> {
        state.shellOptions
    }

    var isErrexitActive: Bool {
        state.isErrexitEnabled
    }

    func shellOptionEnabled(_ name: String) -> Bool {
        state.shellOptions.contains(name)
    }

    func consumePendingShellExitCode() -> Int32? {
        let exitCode = state.pendingShellExitCode
        state.pendingShellExitCode = nil
        return exitCode
    }

    func setPendingShellExitCode(_ exitCode: Int32?) {
        state.pendingShellExitCode = exitCode
    }

    func clearPendingLoopControl() {
        state.pendingLoopControl = nil
    }

    func beginExitTrapIfRunnable() -> String? {
        guard let body = state.shellTraps["EXIT"], !state.runningTraps.contains("EXIT") else {
            return nil
        }
        state.shellTraps.removeValue(forKey: "EXIT")
        state.runningTraps.insert("EXIT")
        return body
    }

    func finishExitTrap(finalExitCode: Int32) -> Int32 {
        let exitCode = state.pendingShellExitCode ?? finalExitCode
        state.pendingFunctionReturnCode = nil
        state.pendingLoopControl = nil
        state.pendingShellExitCode = nil
        state.runningTraps.remove("EXIT")
        return exitCode
    }

    func commandDispatch(for parsed: MSPParsedCommandLine) -> ShellCommandDispatch {
        ShellCommandDispatcher(
            shellFunctions: state.shellFunctions,
            shellFunctionSourceNames: state.shellFunctionSourceNames,
            shellLauncherName: RuntimeShellLauncherNames.shellLauncherName(for:)
        ).dispatch(parsed)
    }

    func storeFunctionDefinition(
        _ definition: MSPParsedFunctionDefinition,
        sourceName: String?
    ) {
        state.shellFunctions[definition.name] = definition
        if let sourceName {
            state.shellFunctionSourceNames[definition.name] = sourceName
        } else {
            state.shellFunctionSourceNames.removeValue(forKey: definition.name)
        }
    }

    func shellFunctionExists(_ name: String) -> Bool {
        state.shellFunctions[name] != nil
    }

    func applyExpansionState(_ expansion: MSPShellCommandSubstitutionExpansion) {
        applyExpansionState(expansion.state)
    }

    func applyExpansionState(_ expansion: MSPShellWordTextExpansionResult) {
        applyExpansionState(expansion.state)
    }

    func applyExpansionState(_ expansion: MSPShellWordExpansionResult) {
        applyExpansionState(expansion.state)
    }

    func applyExpansionState(_ expansionState: MSPShellExpansionState) {
        configuration.environment = expansionState.environment
        state.shellArrays = expansionState.arrays
        state.shellAssociativeArrays = expansionState.associativeArrays
    }

    func shellExpansionContext(
        lastExitCode: Int32,
        enablesPathnameExpansion: Bool = true,
        enablesWordSplitting: Bool = true,
        requiresPathnameCandidates: Bool = true,
        pathnameCandidates: () async throws -> [String]
    ) async throws -> MSPShellExpansionContext {
        let commandContext = configuration.makeCommandContext()
        let effectivePathnameExpansion = enablesPathnameExpansion && !state.shellOptions.contains("noglob")
        let candidates = effectivePathnameExpansion && requiresPathnameCandidates
            ? try await pathnameCandidates()
            : []
        return MSPShellExpansionContext(
            environment: commandContext.environment,
            arrays: state.shellArrays,
            associativeArrays: state.shellAssociativeArrays,
            namerefVariables: state.shellNamerefs,
            specialParameters: shellSpecialParameters(lastExitCode: lastExitCode),
            positionalParameters: Array(state.positionalParameters.dropFirst()),
            currentDirectory: configuration.currentDirectory,
            pathnameCandidates: candidates,
            enablesPathnameExpansion: effectivePathnameExpansion,
            enablesWordSplitting: enablesWordSplitting,
            treatsUnsetParametersAsErrors: state.isNounsetEnabled,
            enablesNullGlob: state.shellOptions.contains("nullglob"),
            enablesFailGlob: state.shellOptions.contains("failglob"),
            enablesDotGlob: state.shellOptions.contains("dotglob"),
            enablesNoCaseGlob: state.shellOptions.contains("nocaseglob"),
            enablesExtendedGlob: state.shellOptions.contains("extglob"),
            enablesGlobStar: state.shellOptions.contains("globstar"),
            ifs: configuration.environment["IFS"] ?? " \t\n",
            enablesBashParameterExtensions: state.enablesBashParameterExtensions,
            enablesBraceExpansion: state.enablesBashParameterExtensions
        )
    }

    func functionDepthValue() -> Int {
        state.functionDepth
    }

    func setFunctionDepth(_ value: Int) {
        state.functionDepth = value
    }

    func positionalParametersValue() -> [String] {
        state.positionalParameters
    }

    func setPositionalParameters(_ value: [String]) {
        state.positionalParameters = value
    }

    func loopDepthValue() -> Int {
        state.loopDepth
    }

    func setLoopDepth(_ value: Int) {
        state.loopDepth = value
    }

    func pendingFunctionReturnCodeValue() -> Int32? {
        state.pendingFunctionReturnCode
    }

    func setPendingFunctionReturnCode(_ value: Int32?) {
        state.pendingFunctionReturnCode = value
    }

    func pendingLoopControlValue() -> MSPShellLoopControl? {
        state.pendingLoopControl
    }

    func setPendingLoopControl(_ value: MSPShellLoopControl?) {
        state.pendingLoopControl = value
    }

    func pendingShellExitCodeValue() -> Int32? {
        state.pendingShellExitCode
    }

    func pushFunctionLocalEnvironmentFrame() {
        state.functionLocalEnvironmentStack.append([:])
    }

    func popFunctionLocalEnvironmentFrame() {
        _ = state.functionLocalEnvironmentStack.popLast()
    }

    func restoreFunctionLocalEnvironmentFrame() {
        guard let frame = state.functionLocalEnvironmentStack.last else {
            return
        }
        for (name, snapshot) in frame {
            configuration.environment[name] = snapshot.environment
            if let array = snapshot.array {
                state.shellArrays[name] = array
            } else {
                state.shellArrays.removeValue(forKey: name)
            }
            if let associativeArray = snapshot.associativeArray {
                state.shellAssociativeArrays[name] = associativeArray
            } else {
                state.shellAssociativeArrays.removeValue(forKey: name)
            }
            if let nameref = snapshot.nameref {
                state.shellNamerefs[name] = nameref
            } else {
                state.shellNamerefs.removeValue(forKey: name)
            }
            if snapshot.wasExported {
                state.exportedVariableNames.insert(name)
            } else {
                state.exportedVariableNames.remove(name)
            }
            if snapshot.wasReadonly {
                state.readonlyVariableNames.insert(name)
            } else {
                state.readonlyVariableNames.remove(name)
            }
        }
    }

    func currentDiagnosticContext(configuredContext: MSPShellDiagnosticContext?) -> MSPShellDiagnosticContext? {
        shellDiagnostics(configuredContext: configuredContext).currentContext
    }

    func shellDiagnostics(configuredContext: MSPShellDiagnosticContext?) -> ShellExecutionDiagnostics {
        ShellExecutionDiagnostics(
            contextStack: state.shellDiagnosticContextStack,
            configuredContext: configuredContext
        )
    }

    func xtraceDiagnostic(for parsed: MSPParsedCommandLine) -> String {
        ShellExecutionDiagnostics.xtraceDiagnostic(for: parsed, isEnabled: state.isXtraceEnabled)
    }

    func shellFunctionNames() -> Set<String> {
        Set(state.shellFunctions.keys)
    }

    func pushDiagnosticContext(_ context: MSPShellDiagnosticContext) {
        state.shellDiagnosticContextStack.append(context)
    }

    func popDiagnosticContext() {
        _ = state.shellDiagnosticContextStack.popLast()
    }

    func savedEnvironmentValues(for names: [String]) -> [String: String?] {
        Dictionary(uniqueKeysWithValues: names.map { ($0, configuration.environment[$0]) })
    }

    func restoreEnvironmentValues(
        _ values: [String: String?],
        preserving preservedNames: Set<String> = []
    ) {
        for (name, value) in values where !preservedNames.contains(name) {
            configuration.environment[name] = value
        }
    }

    func commandLineRunnerState() -> ShellCommandLineRunnerState {
        ShellCommandLineRunnerState(
            configuration: configuration,
            exportedVariableNames: state.exportedVariableNames
        )
    }

    func restoreCommandLineRunnerState(_ runnerState: ShellCommandLineRunnerState) {
        configuration = runnerState.configuration
        state.exportedVariableNames = runnerState.exportedVariableNames
    }

    func applyCommandContext(_ context: MSPCommandContext) {
        configuration = MSPConfiguration(
            workspace: context.workspace,
            currentDirectory: context.currentDirectory,
            environment: context.environment,
            standardInput: context.standardInput,
            standardInputClosed: context.standardInputClosed,
            standardInputStream: context.standardInputStream,
            standardOutputStream: context.standardOutputStream,
            standardErrorStream: context.standardErrorStream,
            fileCreationMask: context.fileCreationMask,
            policyEngine: context.policyEngine,
            auditSink: context.auditSink
        )
        state.exportedVariableNames = Set(context.environment.keys).union(["OLDPWD"])
    }

    func exportedEnvironment(
        from base: [String: String]? = nil,
        applying assignments: [MSPParsedAssignment] = []
    ) -> [String: String] {
        let source = base ?? configuration.environment
        var environment: [String: String] = [:]
        for name in state.exportedVariableNames {
            if let value = source[name] {
                environment[name] = value
            }
        }
        for assignment in assignments {
            environment[resolvedShellNamerefName(assignment.name)] = assignment.value
        }
        return environment
    }

    func environment(
        _ base: [String: String],
        applying assignments: [MSPParsedAssignment]
    ) -> [String: String] {
        var updated = base
        for assignment in assignments {
            updated[resolvedShellNamerefName(assignment.name)] = assignment.value
        }
        return updated
    }

    func setEnvironmentValue(_ name: String, _ value: String) {
        configuration.environment[name] = value
    }

    func evaluateArithmeticCommand(
        _ expression: String,
        appliesStateChange: Bool = true
    ) throws -> MSPShellArithmeticCommandEvaluation {
        var evaluator = MSPShellArithmeticCommandEvaluator(
            expression: expression,
            environment: configuration.environment,
            arrays: state.shellArrays,
            associativeArrays: state.shellAssociativeArrays,
            namerefVariables: state.shellNamerefs
        )
        let evaluation = try evaluator.evaluate()
        if appliesStateChange {
            configuration.environment = evaluation.environment
            state.shellArrays = evaluation.arrays
            state.shellAssociativeArrays = evaluation.associativeArrays
        }
        return evaluation
    }

    func resolvedShellNamerefName(_ name: String) -> String {
        var current = name
        var seen: Set<String> = []
        while let next = state.shellNamerefs[current],
              shellRuntimeVariableName(next),
              !seen.contains(current) {
            seen.insert(current)
            current = next
        }
        return current
    }

    func shellRuntimeVariableName(_ value: String) -> Bool {
        guard let first = value.first, first == "_" || first.isLetter else {
            return false
        }
        return value.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private func shellSpecialParameters(lastExitCode: Int32) -> [String: String] {
        var parameters: [String: String] = [
            "?": String(lastExitCode),
            "#": String(max(0, state.positionalParameters.count - 1)),
            "@": state.positionalParameters.dropFirst().joined(separator: " "),
            "*": state.positionalParameters.dropFirst().joined(separator: " "),
            "-": shellOptionFlags(),
            "0": state.positionalParameters.first ?? "msp"
        ]
        for (index, value) in state.positionalParameters.dropFirst().enumerated() {
            parameters[String(index + 1)] = value
        }
        return parameters
    }

    private func shellOptionFlags() -> String {
        var flags = ""
        if state.isErrexitEnabled {
            flags += "e"
        }
        if state.shellOptions.contains("noglob") {
            flags += "f"
        }
        flags += "h"
        if state.isNounsetEnabled {
            flags += "u"
        }
        if state.isXtraceEnabled {
            flags += "x"
        }
        if state.enablesBashParameterExtensions {
            flags += "B"
        }
        flags += "c"
        return flags
    }
}
