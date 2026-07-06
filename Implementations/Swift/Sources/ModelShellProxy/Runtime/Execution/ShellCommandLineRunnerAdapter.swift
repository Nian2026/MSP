import MSPCore

struct ShellCommandLineRunnerAdapter {
    var captureState: () -> ShellCommandLineRunnerState
    var restoreState: (ShellCommandLineRunnerState) -> Void
    var applyContext: (MSPCommandContext) -> Void
    var runCommandLine: (
        String,
        (any MSPCommandOutputStream)?,
        (any MSPCommandOutputStream)?
    ) async -> MSPCommandResult

    func makeRunner() -> MSPCommandLineRunner {
        { commandLine, context in
            let previousState = captureState()
            applyContext(context)
            let result = await runCommandLine(
                commandLine,
                context.standardOutputStream,
                context.standardErrorStream
            )
            restoreState(previousState)
            return result
        }
    }
}

extension ModelShellProxy {
    func makeCommandLineRunner() -> MSPCommandLineRunner {
        ShellCommandLineRunnerAdapter(
            captureState: { [self] in
                runtime.commandLineRunnerState()
            },
            restoreState: { [self] state in
                runtime.restoreCommandLineRunnerState(state)
            },
            applyContext: { [self] context in
                runtime.applyCommandContext(context)
            },
            runCommandLine: { [self] commandLine, outputStream, errorStream in
                await run(commandLine, outputStream: outputStream, errorStream: errorStream)
            }
        ).makeRunner()
    }
}
