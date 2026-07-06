import MSPCore
import MSPShell

extension ShellRuntime {
    func executeEvalCommand(
        _ request: ShellSingleCommandEvalRequest,
        ports: ShellRuntimeReentryPorts
    ) async -> MSPCommandResult {
        await scriptReentryRuntime(ports: ports).executeEvalCommand(request)
    }

    func executeSourceCommand(
        _ request: ShellSingleCommandSourceRequest,
        ports: ShellRuntimeReentryPorts
    ) async -> MSPCommandResult {
        await scriptReentryRuntime(ports: ports).executeSourceCommand(request)
    }

    func executePathScriptCommand(
        _ request: ShellSingleCommandPathScriptRequest,
        ports: ShellRuntimeReentryPorts
    ) async -> MSPCommandResult {
        await scriptReentryRuntime(ports: ports).executePathScriptCommand(request)
    }

    func executeShellLauncherCommand(
        _ request: ShellSingleCommandShellLauncherRequest,
        ports: ShellRuntimeReentryPorts
    ) async -> MSPCommandResult {
        await scriptReentryRuntime(ports: ports).executeShellLauncherCommand(request)
    }

    private func scriptReentryRuntime(
        ports: ShellRuntimeReentryPorts
    ) -> ShellScriptReentryRuntime {
        ShellScriptReentryRuntime(
            context: ShellScriptReentryRuntimeContext(
                parser: parser,
                runtimeBuiltinContext: { [self] in
                    runtimeBuiltinContext()
                },
                applyRuntimeBuiltinContext: { [self] context in
                    applyRuntimeBuiltinContext(context)
                },
                captureState: { [self] in
                    captureState()
                },
                restoreState: { [self] state in
                    restoreState(state)
                },
                workspace: { [self] in
                    configuration.workspace
                },
                currentDirectory: { [self] in
                    configuration.currentDirectory
                },
                currentDiagnosticContext: { [self] in
                    reentryShellDiagnostics.currentContext
                },
                diagnosticReason: ports.diagnostics.diagnosticReason,
                shellDiagnostic: { [self] message, lineNumber in
                    reentryShellDiagnostics.diagnostic(message, lineNumber: lineNumber)
                },
                runCommandLine: { [self] request in
                    await runRuntimeReentryCommandLine(request, ports: ports)
                },
                runScript: { [self] request in
                    await runRuntimeReentryScript(request, ports: ports)
                }
            )
        )
    }

    private var reentryShellDiagnostics: ShellExecutionDiagnostics {
        shellDiagnostics(
            configuredContext: ShellExecutionDiagnostics.configuredContext(
                for: configuration.shellDiagnosticProfile
            )
        )
    }

    private func runRuntimeReentryCommandLine(
        _ request: RuntimeReentryCommandLineRunRequest,
        ports: ShellRuntimeReentryPorts
    ) async -> MSPCommandResult {
        await runWithScopedOutputBindings(
            stdoutBinding: request.io.stdoutBinding,
            stderrBinding: request.io.stderrBinding
        ) {
            let streams = visibleOutputStreams(
                outputStream: request.io.outputStream,
                errorStream: request.io.errorStream
            )
            var scopedRequest = request
            scopedRequest.io.outputStream = streams.outputStream
            scopedRequest.io.errorStream = streams.errorStream
            return await ports.commands.runCommandLine(scopedRequest)
        }
    }

    private func runRuntimeReentryScript(
        _ request: RuntimeReentryScriptRunRequest,
        ports: ShellRuntimeReentryPorts
    ) async -> MSPCommandResult {
        await runWithScopedOutputBindings(
            stdoutBinding: request.io.stdoutBinding,
            stderrBinding: request.io.stderrBinding
        ) {
            let streams = visibleOutputStreams(
                outputStream: request.io.outputStream,
                errorStream: request.io.errorStream
            )
            return await loadedScriptRuntime(ports: ports).runIncrementally(
                request.script,
                initialLastExitCode: request.io.lastExitCode,
                outputStream: streams.outputStream,
                errorStream: streams.errorStream
            )
        }
    }

    private func loadedScriptRuntime(
        ports: ShellRuntimeReentryPorts
    ) -> ShellLoadedScriptRuntime {
        ShellLoadedScriptRuntime(
            context: ShellLoadedScriptRuntimeContext(
                parser: parser,
                shellOptions: { [self] in
                    shellOptionsSnapshot
                },
                hasPendingShellControl: { [self] in
                    hasPendingShellControl
                },
                isErrexitEnabled: { [self] in
                    isErrexitActive
                },
                pendingShellExitCode: { [self] in
                    pendingShellExitCodeValue()
                },
                setPendingShellExitCode: { [self] exitCode in
                    setPendingShellExitCode(exitCode)
                },
                clearPendingLoopControl: { [self] in
                    clearPendingLoopControl()
                },
                runCommandText: ports.commands.runLoadedScriptRecord,
                runExitTrapIfNeeded: { [self] finalExitCode in
                    await runExitTrapIfNeeded(
                        finalExitCode: finalExitCode,
                        ports: ports.exitTrap
                    )
                }
            )
        )
    }
}
