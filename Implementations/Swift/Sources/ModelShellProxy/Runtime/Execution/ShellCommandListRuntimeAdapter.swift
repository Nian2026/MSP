import MSPCore
import MSPShell

struct ShellRuntimeCommandListRunOptions {
    var initialLastExitCode: Int32
    var clearsShellControlAtEnd: Bool
    var suppressesErrexit: Bool
    var sourceLineOffset: Int
    var syntaxDiagnosticCommandName: String?
    var outputStream: (any MSPCommandOutputStream)?
    var errorStream: (any MSPCommandOutputStream)?
}

struct ShellRuntimeCommandListPorts {
    var runPipeline: (
        MSPParsedCommandPipeline,
        String,
        Int32,
        Int?,
        (any MSPCommandOutputStream)?,
        (any MSPCommandOutputStream)?
    ) async -> MSPCommandResult
    var runExitTrap: (Int32) async -> MSPCommandResult?
}

extension ShellRuntime {
    func runCommandListLine(
        _ commandLine: String,
        options: ShellRuntimeCommandListRunOptions,
        ports: ShellRuntimeCommandListPorts
    ) async -> MSPCommandResult {
        await ShellCommandListRunner.runCommandLine(
            commandLine,
            context: commandListRunnerContext(
                options: options,
                ports: ports
            )
        )
    }

    func runCommandList(
        _ commandList: MSPParsedCommandList,
        options: ShellRuntimeCommandListRunOptions,
        ports: ShellRuntimeCommandListPorts
    ) async -> MSPCommandResult {
        await ShellCommandListRunner.run(
            commandList,
            context: commandListRunnerContext(
                options: options,
                ports: ports
            )
        )
    }

    private func commandListRunnerContext(
        options: ShellRuntimeCommandListRunOptions,
        ports: ShellRuntimeCommandListPorts
    ) -> ShellCommandListRunnerContext {
        ShellCommandListRunnerContext(
            initialLastExitCode: options.initialLastExitCode,
            clearsShellControlAtEnd: options.clearsShellControlAtEnd,
            suppressesErrexit: options.suppressesErrexit,
            sourceLineOffset: options.sourceLineOffset,
            syntaxDiagnosticCommandName: options.syntaxDiagnosticCommandName,
            outputStream: options.outputStream,
            errorStream: options.errorStream,
            parsePipelines: { [self] commandLine in
                try parser.parseExecutablePipelines(
                    commandLine,
                    enablesExtendedGlob: shellOptionEnabled("extglob")
                )
            },
            parserSyntaxFailureResult: { [self] exitCode, message, lineNumber, commandName, commandLine in
                self.commandListParserSyntaxFailureResult(
                    exitCode: exitCode,
                    message: message,
                    lineNumber: lineNumber,
                    commandName: commandName,
                    commandLine: commandLine
                )
            },
            runPipeline: ports.runPipeline,
            hasPendingShellControl: { [self] in
                hasPendingShellControl
            },
            consumePendingShellExitCode: { [self] in
                consumePendingShellExitCode()
            },
            clearPendingLoopControl: { [self] in
                clearPendingLoopControl()
            },
            runExitTrap: ports.runExitTrap,
            isErrexitEnabled: { [self] in
                isErrexitActive
            }
        )
    }

    private func commandListParserSyntaxFailureResult(
        exitCode: Int32,
        message: String,
        lineNumber: Int,
        commandName: String?,
        commandLine: String
    ) -> MSPCommandResult {
        shellDiagnostics(
            configuredContext: ShellExecutionDiagnostics.configuredContext(
                for: configuration.shellDiagnosticProfile
            )
        )
        .parserSyntaxFailureResult(
            exitCode: exitCode,
            message: message,
            lineNumber: lineNumber,
            commandName: commandName,
            commandLine: commandLine
        )
    }
}
