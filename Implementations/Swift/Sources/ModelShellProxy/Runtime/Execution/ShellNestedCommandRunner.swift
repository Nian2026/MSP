import Foundation
import MSPCore
import MSPShell

struct ShellNestedCommandRunner {
    var captureState: () -> ShellRuntimeState
    var restoreState: (ShellRuntimeState) -> Void
    var setStandardInput: (Data, Bool) -> Void
    var clearStandardInputFileDescriptor: () -> Void
    var setStdoutBinding: (MSPRedirectionOutputBinding) -> Void
    var setStderrBinding: (MSPRedirectionOutputBinding) -> Void
    var runCommandLine: (String, Int32) async -> MSPCommandResult

    func runCommandSubstitution(
        _ commandLine: String,
        standardInput: Data,
        standardInputClosed: Bool,
        standardInputOverridesFileDescriptor: Bool,
        lastExitCode: Int32
    ) async -> MSPShellCommandSubstitutionResult {
        let result = await runNestedCommand(
            commandLine,
            standardInput: standardInput,
            standardInputClosed: standardInputClosed,
            standardInputOverridesFileDescriptor: standardInputOverridesFileDescriptor,
            lastExitCode: lastExitCode,
            stdoutBinding: .agentStdout,
            stderrBinding: nil
        )
        return MSPShellCommandSubstitutionResult(
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode
        )
    }

    func runProcessSubstitutionCommand(
        _ commandLine: String,
        standardInput: Data,
        standardInputClosed: Bool,
        standardInputOverridesFileDescriptor: Bool,
        lastExitCode: Int32
    ) async -> MSPCommandResult {
        await runNestedCommand(
            commandLine,
            standardInput: standardInput,
            standardInputClosed: standardInputClosed,
            standardInputOverridesFileDescriptor: standardInputOverridesFileDescriptor,
            lastExitCode: lastExitCode,
            stdoutBinding: .agentStdout,
            stderrBinding: .agentStderr
        )
    }

    private func runNestedCommand(
        _ commandLine: String,
        standardInput: Data,
        standardInputClosed: Bool,
        standardInputOverridesFileDescriptor: Bool,
        lastExitCode: Int32,
        stdoutBinding: MSPRedirectionOutputBinding,
        stderrBinding: MSPRedirectionOutputBinding?
    ) async -> MSPCommandResult {
        let previousState = captureState()
        setStandardInput(standardInput, standardInputClosed)
        if standardInputOverridesFileDescriptor {
            clearStandardInputFileDescriptor()
        }
        setStdoutBinding(stdoutBinding)
        if let stderrBinding {
            setStderrBinding(stderrBinding)
        }
        let result = await runCommandLine(commandLine, lastExitCode)
        restoreState(previousState)
        return result
    }
}

extension ModelShellProxy {
    private func makeNestedCommandRunner() -> ShellNestedCommandRunner {
        ShellNestedCommandRunner(
            captureState: { [self] in runtime.captureState() },
            restoreState: { [self] state in runtime.restoreState(state) },
            setStandardInput: { [self] standardInput, standardInputClosed in
                var childConfiguration = configuration
                childConfiguration.standardInput = standardInput
                childConfiguration.standardInputClosed = standardInputClosed
                configuration = childConfiguration
            },
            clearStandardInputFileDescriptor: { [self] in
                persistentInputFileDescriptors.removeValue(forKey: 0)
                persistentClosedInputFileDescriptors.remove(0)
            },
            setStdoutBinding: { [self] binding in
                persistentStdoutBinding = binding
            },
            setStderrBinding: { [self] binding in
                persistentStderrBinding = binding
            },
            runCommandLine: { [self] commandLine, lastExitCode in
                await run(commandLine, initialLastExitCode: lastExitCode)
            }
        )
    }

    func runCommandSubstitution(
        _ commandLine: String,
        standardInput: Data,
        standardInputClosed: Bool = false,
        standardInputOverridesFileDescriptor: Bool = false,
        lastExitCode: Int32
    ) async -> MSPShellCommandSubstitutionResult {
        await makeNestedCommandRunner().runCommandSubstitution(
            commandLine,
            standardInput: standardInput,
            standardInputClosed: standardInputClosed,
            standardInputOverridesFileDescriptor: standardInputOverridesFileDescriptor,
            lastExitCode: lastExitCode
        )
    }

    func runProcessSubstitutionCommand(
        _ commandLine: String,
        standardInput: Data,
        standardInputClosed: Bool = false,
        standardInputOverridesFileDescriptor: Bool = false,
        lastExitCode: Int32
    ) async -> MSPCommandResult {
        await makeNestedCommandRunner().runProcessSubstitutionCommand(
            commandLine,
            standardInput: standardInput,
            standardInputClosed: standardInputClosed,
            standardInputOverridesFileDescriptor: standardInputOverridesFileDescriptor,
            lastExitCode: lastExitCode
        )
    }
}
