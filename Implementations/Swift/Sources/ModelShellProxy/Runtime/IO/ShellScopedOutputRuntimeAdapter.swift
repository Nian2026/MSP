import Foundation
import MSPCore

extension ShellRuntime {
    func runWithScopedOutputBindings(
        stdoutBinding: MSPRedirectionOutputBinding?,
        stderrBinding: MSPRedirectionOutputBinding?,
        body: () async -> MSPCommandResult
    ) async -> MSPCommandResult {
        let previousStdoutBinding = io.persistentStdoutBinding
        let previousStderrBinding = io.persistentStderrBinding
        if let stdoutBinding {
            io.persistentStdoutBinding = stdoutBinding
        }
        if let stderrBinding {
            io.persistentStderrBinding = stderrBinding
        }
        let result = await body()
        if stdoutBinding != nil {
            io.persistentStdoutBinding = previousStdoutBinding
        }
        if stderrBinding != nil {
            io.persistentStderrBinding = previousStderrBinding
        }
        return result
    }

    func runWithScopedFileDescriptorRouting(
        _ routing: MSPRedirectionRouting,
        touchedFileDescriptors: Set<Int>,
        body: () async -> MSPCommandResult
    ) async -> MSPCommandResult {
        guard let scope = io.beginScopedFileDescriptorRouting(
            routing,
            touchedFileDescriptors: touchedFileDescriptors,
            standardInput: configuration.standardInput
        ) else {
            return await body()
        }

        let result = await body()
        var standardInput = configuration.standardInput
        io.endScopedFileDescriptorRouting(scope, standardInput: &standardInput)
        configuration.standardInput = standardInput
        return result
    }

    func visibleOutputStreams(
        outputStream: (any MSPCommandOutputStream)?,
        errorStream: (any MSPCommandOutputStream)?
    ) -> (
        outputStream: (any MSPCommandOutputStream)?,
        errorStream: (any MSPCommandOutputStream)?
    ) {
        let streams = ShellOutputForwarding.visibleStreams(
            stdoutBinding: io.persistentStdoutBinding,
            stderrBinding: io.persistentStderrBinding,
            outputStream: outputStream,
            errorStream: errorStream
        )
        return (
            outputStream: streams.outputStream,
            errorStream: streams.errorStream
        )
    }
}
