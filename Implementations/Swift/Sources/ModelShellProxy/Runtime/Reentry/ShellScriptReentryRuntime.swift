import Foundation
import MSPCore
import MSPShell

struct ShellScriptReentryRuntimeContext {
    var parser: MSPShellParser
    var runtimeBuiltinContext: () -> RuntimeBuiltinContext
    var applyRuntimeBuiltinContext: (RuntimeBuiltinContext) -> Void
    var captureState: () -> ShellRuntimeState
    var restoreState: (ShellRuntimeState) -> Void
    var workspace: () -> (any MSPWorkspace)?
    var currentDirectory: () -> String
    var currentDiagnosticContext: () -> MSPShellDiagnosticContext?
    var diagnosticReason: (Error) -> String
    var shellDiagnostic: (String, Int?) -> String
    var runCommandLine: RuntimeReentryCommandLineRunner
    var runScript: RuntimeReentryScriptRunner
}

struct ShellScriptReentryRuntime {
    var context: ShellScriptReentryRuntimeContext

    func executeEvalCommand(
        _ request: ShellSingleCommandEvalRequest
    ) async -> MSPCommandResult {
        let commandLine = request.arguments.joined(separator: " ")
        guard !commandLine.isEmpty else {
            return .success()
        }

        var builtin = context.runtimeBuiltinContext()
        let isolatedState = request.appliesStateChange ? nil : context.captureState()
        let previousStandardInput = builtin.configuration.standardInput
        let previousStandardInputClosed = builtin.configuration.standardInputClosed
        builtin.configuration.standardInput = request.io.standardInput
        builtin.configuration.standardInputClosed = request.io.standardInputClosed
        context.applyRuntimeBuiltinContext(builtin)

        let result = await context.runCommandLine(
            RuntimeReentryCommandLineRunRequest(
                commandLine: commandLine,
                io: runtimeReentryIO(request.io),
                syntaxDiagnosticCommandName: "eval"
            )
        )
        builtin = context.runtimeBuiltinContext()
        if let isolatedState {
            context.restoreState(isolatedState)
        } else if request.hasInputRedirection {
            builtin.configuration.standardInput = previousStandardInput
            builtin.configuration.standardInputClosed = previousStandardInputClosed
            context.applyRuntimeBuiltinContext(builtin)
        }
        return result
    }

    func executeSourceCommand(
        _ request: ShellSingleCommandSourceRequest
    ) async -> MSPCommandResult {
        guard let scriptPath = request.arguments.first else {
            return .failure(exitCode: 2, stderr: "\(request.commandName): filename argument required\n")
        }

        let script: String
        do {
            script = try sourceScriptText(path: scriptPath, commandName: request.commandName)
        } catch let failure as MSPCommandFailure {
            return failure.result
        } catch {
            return .failure(exitCode: 1, stderr: "\(request.commandName): \(error)\n")
        }

        var builtin = context.runtimeBuiltinContext()
        let isolatedState = request.appliesStateChange ? nil : context.captureState()
        let previousPositionalParameters = builtin.positionalParameters
        let previousStandardInput = builtin.configuration.standardInput
        let previousStandardInputClosed = builtin.configuration.standardInputClosed
        if request.arguments.count > 1 {
            builtin.positionalParameters = [builtin.positionalParameters.first ?? "msp"]
                + Array(request.arguments.dropFirst())
        }
        builtin.configuration.standardInput = request.io.standardInput
        builtin.configuration.standardInputClosed = request.io.standardInputClosed
        builtin.sourceDepth += 1
        if let currentDiagnosticContext = builtin.diagnostics.currentContext {
            builtin.shellDiagnosticContextStack.append(
                MSPShellDiagnosticContext(
                    scriptName: scriptPath,
                    style: currentDiagnosticContext.style
                )
            )
        }
        context.applyRuntimeBuiltinContext(builtin)

        let result = await context.runCommandLine(
            RuntimeReentryCommandLineRunRequest(
                commandLine: script,
                io: runtimeReentryIO(request.io),
                syntaxDiagnosticCommandName: nil
            )
        )
        builtin = context.runtimeBuiltinContext()
        if builtin.diagnostics.currentContext != nil {
            _ = builtin.shellDiagnosticContextStack.popLast()
        }
        builtin.sourceDepth -= 1

        var sourceResult = result
        if let returnCode = builtin.pendingFunctionReturnCode {
            builtin.pendingFunctionReturnCode = nil
            sourceResult.exitCode = returnCode
        }
        if let isolatedState {
            context.restoreState(isolatedState)
        } else {
            builtin.positionalParameters = previousPositionalParameters
            builtin.configuration.standardInput = previousStandardInput
            builtin.configuration.standardInputClosed = previousStandardInputClosed
            context.applyRuntimeBuiltinContext(builtin)
        }
        return sourceResult
    }

    func executeShellLauncherCommand(
        _ request: ShellSingleCommandShellLauncherRequest
    ) async -> MSPCommandResult {
        if request.shellLauncherName == "bash",
           request.arguments.contains("--version") {
            return .success(stdout: "GNU bash, version 5.2.15(1)-release (x86_64-pc-linux-gnu)\n")
        }
        let launch: ShellLauncherInvocation
        do {
            launch = try shellLauncherInvocation(
                commandName: request.commandName,
                shellLauncherName: request.shellLauncherName,
                arguments: request.arguments,
                standardInput: request.io.standardInput,
                standardInputClosed: request.io.standardInputClosed
            )
        } catch let failure as MSPCommandFailure {
            return failure.result
        } catch {
            return .failure(exitCode: 1, stderr: "\(request.commandName): \(error)\n")
        }

        return await executeLoadedShellScriptCommand(
            RuntimeLoadedShellScriptCommandRequest(
                scriptName: launch.scriptName,
                shellLauncherName: request.shellLauncherName,
                script: launch.script,
                arguments: launch.positionalParameters,
                io: RuntimeReentryIO(
                    standardInput: launch.standardInput,
                    standardInputClosed: launch.standardInputClosed,
                    stdoutBinding: request.io.stdoutBinding,
                    stderrBinding: request.io.stderrBinding,
                    lastExitCode: request.io.lastExitCode,
                    outputStream: request.io.outputStream,
                    errorStream: request.io.errorStream
                ),
                syntaxCheckOnly: launch.syntaxCheckOnly,
                childErrexit: launch.errexitEnabled,
                childNounset: launch.nounsetEnabled,
                childPipefail: launch.pipefailEnabled
            )
        )
    }

    func executePathScriptCommand(
        _ request: ShellSingleCommandPathScriptRequest
    ) async -> MSPCommandResult {
        guard let workspace = context.workspace() else {
            return pathCommandFailure(
                commandName: request.commandName,
                message: "No such file or directory",
                exitCode: 127,
                sourceLineNumber: request.sourceLineNumber
            )
        }

        let resolvedPath: String
        let info: MSPFileInfo
        do {
            let resolved = try workspace.fileSystem.resolve(request.commandName, from: context.currentDirectory())
            resolvedPath = resolved.virtualPath
            info = try workspace.fileSystem.stat(resolved.virtualPath, from: "/")
        } catch {
            return pathCommandFailure(
                commandName: request.commandName,
                message: "No such file or directory",
                exitCode: 127,
                sourceLineNumber: request.sourceLineNumber
            )
        }

        if info.type == .directory {
            return pathCommandFailure(
                commandName: request.commandName,
                message: "Is a directory",
                exitCode: 126,
                sourceLineNumber: request.sourceLineNumber
            )
        }
        if let permissions = info.permissions,
           (permissions & 0o111) == 0 {
            return pathCommandFailure(
                commandName: request.commandName,
                message: "Permission denied",
                exitCode: 126,
                sourceLineNumber: request.sourceLineNumber
            )
        }

        let script: String
        do {
            let data = try workspace.fileSystem.readFile(resolvedPath, from: "/")
            script = String(decoding: data, as: UTF8.self)
        } catch {
            return pathCommandFailure(
                commandName: request.commandName,
                message: "No such file or directory",
                exitCode: 127,
                sourceLineNumber: request.sourceLineNumber
            )
        }

        guard let launcher = RuntimeShellLauncherNames.scriptLauncher(for: script) else {
            return pathCommandFailure(
                commandName: request.commandName,
                message: "cannot execute: required interpreter is not available",
                exitCode: 126,
                sourceLineNumber: request.sourceLineNumber
            )
        }

        if case .command(let name, let interpreterArguments) = launcher {
            let commandLine = ([name] + interpreterArguments + [request.commandName] + request.arguments)
                .map(shellQuote)
                .joined(separator: " ")
            return await context.runCommandLine(
                RuntimeReentryCommandLineRunRequest(
                    commandLine: commandLine,
                    io: runtimeReentryIO(request.io),
                    syntaxDiagnosticCommandName: nil
                )
            )
        }

        guard case .shell(let shellLauncherName) = launcher else {
            return pathCommandFailure(
                commandName: request.commandName,
                message: "cannot execute: required interpreter is not available",
                exitCode: 126,
                sourceLineNumber: request.sourceLineNumber
            )
        }

        return await executeLoadedShellScriptCommand(
            RuntimeLoadedShellScriptCommandRequest(
                scriptName: request.commandName,
                shellLauncherName: shellLauncherName,
                script: script,
                arguments: request.arguments,
                io: runtimeReentryIO(request.io),
                syntaxCheckOnly: false,
                childErrexit: nil,
                childNounset: nil,
                childPipefail: nil
            )
        )
    }

    private func executeLoadedShellScriptCommand(
        _ request: RuntimeLoadedShellScriptCommandRequest
    ) async -> MSPCommandResult {
        if request.syntaxCheckOnly {
            return checkLoadedShellScriptSyntax(
                request.script,
                enablesExtendedGlob: context.runtimeBuiltinContext().shellOptions.contains("extglob")
            )
        }

        let previousState = context.captureState()
        var builtin = context.runtimeBuiltinContext()
        builtin.positionalParameters = [request.scriptName] + request.arguments
        builtin.configuration.standardInput = request.io.standardInput
        builtin.configuration.standardInputClosed = request.io.standardInputClosed
        builtin.isErrexitEnabled = request.childErrexit ?? builtin.isErrexitEnabled
        builtin.isNounsetEnabled = request.childNounset ?? builtin.isNounsetEnabled
        builtin.isPipefailEnabled = request.childPipefail ?? builtin.isPipefailEnabled
        builtin.enablesBashParameterExtensions = request.shellLauncherName != "sh"
        builtin.shellDiagnosticContextStack.append(
            MSPShellDiagnosticContext(
                scriptName: request.scriptName,
                style: request.shellLauncherName == "sh" ? .dash : .bash
            )
        )
        context.applyRuntimeBuiltinContext(builtin)

        var result = await context.runScript(
            RuntimeReentryScriptRunRequest(
                script: request.script,
                io: request.io
            )
        )
        builtin = context.runtimeBuiltinContext()
        _ = builtin.shellDiagnosticContextStack.popLast()
        if request.shellLauncherName == "sh" {
            result = ShellExecutionDiagnostics.dashShellDiagnosticResult(
                result,
                scriptName: request.scriptName
            )
        }
        context.restoreState(previousState)
        return result
    }

    func sourceScriptText(path: String, commandName: String) throws -> String {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MSPCommandFailure(result: .failure(exitCode: 2, stderr: "\(commandName): filename argument required\n"))
        }
        guard let workspace = context.workspace() else {
            throw MSPCommandFailure(result: .failure(exitCode: 1, stderr: "\(commandName): workspace is required\n"))
        }

        do {
            let data = try workspace.fileSystem.readFile(path, from: context.currentDirectory())
            return String(decoding: data, as: UTF8.self)
        } catch {
            if context.currentDiagnosticContext() != nil {
                throw MSPCommandFailure(
                    result: .failure(
                        exitCode: 1,
                        stderr: context.shellDiagnostic("\(path): \(context.diagnosticReason(error))", nil)
                    )
                )
            }
            throw MSPCommandFailure(
                result: .failure(
                    exitCode: 1,
                    stderr: "\(commandName): \(path): \(context.diagnosticReason(error))\n"
                )
            )
        }
    }

    private func checkLoadedShellScriptSyntax(
        _ script: String,
        enablesExtendedGlob: Bool
    ) -> MSPCommandResult {
        do {
            _ = try context.parser.parseExecutablePipelines(
                script,
                enablesExtendedGlob: enablesExtendedGlob
            )
            return .success()
        } catch MSPShellParserError.emptyInput {
            return .success()
        } catch MSPShellParserError.syntax(let exitCode, let message) {
            return .failure(exitCode: Int32(exitCode), stderr: message.hasSuffix("\n") ? message : message + "\n")
        } catch MSPShellParserError.unsupportedExecutionForm(let message) {
            return .failure(exitCode: 2, stderr: message.hasSuffix("\n") ? message : message + "\n")
        } catch {
            return .failure(exitCode: 2, stderr: "\(error)\n")
        }
    }

    private func runtimeReentryIO(_ io: ShellSingleCommandReentryIO) -> RuntimeReentryIO {
        RuntimeReentryIO(
            standardInput: io.standardInput,
            standardInputClosed: io.standardInputClosed,
            stdoutBinding: io.stdoutBinding,
            stderrBinding: io.stderrBinding,
            lastExitCode: io.lastExitCode,
            outputStream: io.outputStream,
            errorStream: io.errorStream
        )
    }

    private func shellQuote(_ value: String) -> String {
        if value.isEmpty {
            return "''"
        }
        let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if value.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func pathCommandFailure(
        commandName: String,
        message: String,
        exitCode: Int32,
        sourceLineNumber: Int?
    ) -> MSPCommandResult {
        .failure(
            exitCode: exitCode,
            stderr: context.shellDiagnostic("\(commandName): \(message)", sourceLineNumber)
        )
    }
}
