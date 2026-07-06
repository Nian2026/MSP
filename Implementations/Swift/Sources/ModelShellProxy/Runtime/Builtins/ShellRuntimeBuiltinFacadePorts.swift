import MSPCore
import MSPShell

extension ModelShellProxy {
    func shellRuntimeBuiltinPorts() -> ShellRuntimeBuiltinPorts {
        ShellRuntimeBuiltinPorts(
            readInput: { [self] fd, routing, mode in
                try await readCommandInput(for: fd, routing: routing, mode: mode)
            },
            consumeInputDescription: { [self] descriptionID, byteCount in
                consumeInputOpenFileDescription(id: descriptionID, byteCount: byteCount)
            },
            snapshotPersistentBindings: { [self] in
                RuntimeExecPersistentBindingSnapshot(
                    stdoutBinding: persistentStdoutBinding,
                    stderrBinding: persistentStderrBinding,
                    outputFileDescriptors: runtime.io.persistentOutputFileDescriptors,
                    inputFileDescriptors: runtime.io.persistentInputFileDescriptors,
                    closedInputFileDescriptors: runtime.io.persistentClosedInputFileDescriptors,
                    inputOpenFileDescriptions: runtime.io.inputOpenFileDescriptions,
                    nextInputOpenFileID: runtime.io.nextInputOpenFileID
                )
            },
            restorePersistentBindings: { [self] snapshot in
                persistentStdoutBinding = snapshot.stdoutBinding
                persistentStderrBinding = snapshot.stderrBinding
                runtime.io.persistentOutputFileDescriptors = snapshot.outputFileDescriptors
                runtime.io.persistentInputFileDescriptors = snapshot.inputFileDescriptors
                runtime.io.persistentClosedInputFileDescriptors = snapshot.closedInputFileDescriptors
                runtime.io.inputOpenFileDescriptions = snapshot.inputOpenFileDescriptions
                runtime.io.nextInputOpenFileID = snapshot.nextInputOpenFileID
            },
            applyPersistentRedirections: { [self] redirections, standardInput, standardInputClosed in
                try applyPersistentExecRedirections(
                    redirections,
                    standardInput: &standardInput,
                    standardInputClosed: &standardInputClosed
                )
            }
        )
    }

    func exitTrapRuntimePorts() -> ShellRuntimeExitTrapPorts {
        ShellRuntimeExitTrapPorts(
            runCommandText: { [self] commandText, initialLastExitCode in
                await run(
                    commandText,
                    initialLastExitCode: initialLastExitCode,
                    clearsShellControlAtEnd: false,
                    suppressesErrexit: true
                )
            }
        )
    }
}
