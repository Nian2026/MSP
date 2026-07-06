import MSPCore
import MSPShell

extension ModelShellProxy {
    func shellRuntimeReentryPorts() -> ShellRuntimeReentryPorts {
        ShellRuntimeReentryPorts(
            commands: shellRuntimeReentryCommandPorts(),
            diagnostics: shellRuntimeReentryDiagnosticsPorts(),
            io: shellRuntimeReentryIOPorts(),
            expansion: shellRuntimeReentryExpansionPorts(),
            exitTrap: exitTrapRuntimePorts()
        )
    }

    private func shellRuntimeReentryCommandPorts() -> ShellRuntimeReentryCommandPorts {
        ShellRuntimeReentryCommandPorts(
            runCommandLine: { [self] request in
                await run(
                    request.commandLine,
                    initialLastExitCode: request.io.lastExitCode,
                    syntaxDiagnosticCommandName: request.syntaxDiagnosticCommandName,
                    standardInput: request.io.standardInput,
                    standardInputClosed: request.io.standardInputClosed,
                    outputStream: request.io.outputStream,
                    errorStream: request.io.errorStream
                )
            },
            runLoadedScriptRecord: { [self] request in
                await run(
                    request.commandText,
                    initialLastExitCode: request.initialLastExitCode,
                    sourceLineOffset: request.sourceLineOffset,
                    outputStream: request.outputStream,
                    errorStream: request.errorStream
                )
            },
            runCommandList: { [self] request in
                await run(
                    request.commandList,
                    initialLastExitCode: request.initialLastExitCode,
                    suppressesErrexit: request.suppressesErrexit,
                    sourceLineOffset: request.sourceLineOffset,
                    outputStream: request.outputStream,
                    errorStream: request.errorStream
                )
            },
            runCommandText: { [self] request in
                await run(
                    request.commandText,
                    initialLastExitCode: request.initialLastExitCode,
                    suppressesErrexit: request.suppressesErrexit,
                    sourceLineOffset: request.sourceLineOffset,
                    outputStream: request.outputStream,
                    errorStream: request.errorStream
                )
            }
        )
    }

    private func shellRuntimeReentryDiagnosticsPorts() -> ShellRuntimeReentryDiagnosticsPorts {
        ShellRuntimeReentryDiagnosticsPorts(
            diagnosticReason: { [self] error in
                redirectionDiagnosticReason(from: error)
            }
        )
    }

    private func shellRuntimeReentryIOPorts() -> ShellRuntimeReentryIOPorts {
        ShellRuntimeReentryIOPorts(
            applyRedirections: { [self] redirections, standardInput, standardInputClosed, currentDirectory, stdoutBinding, stderrBinding in
                try applyRedirections(
                    redirections,
                    standardInput: standardInput,
                    standardInputClosed: standardInputClosed,
                    currentDirectory: currentDirectory,
                    stdoutBindingOverride: stdoutBinding,
                    stderrBindingOverride: stderrBinding
                )
            },
            finalizeRedirections: { [self] routing, result, processSubstitutionStartIndex in
                try await finalizeRedirections(
                    routing,
                    result: result,
                    processSubstitutionStartIndex: processSubstitutionStartIndex
                )
            },
            remainingInputData: { [self] descriptionID in
                try remainingInputData(for: descriptionID)
            }
        )
    }
}
