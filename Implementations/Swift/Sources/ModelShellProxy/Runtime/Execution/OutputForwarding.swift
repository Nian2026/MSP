import Foundation
import MSPCore

struct ShellVisibleOutputStreams {
    var outputStream: (any MSPCommandOutputStream)?
    var errorStream: (any MSPCommandOutputStream)?
}

struct ShellOutputForwarding {
    static func visibleStreams(
        stdoutBinding: MSPRedirectionOutputBinding,
        stderrBinding: MSPRedirectionOutputBinding,
        outputStream: (any MSPCommandOutputStream)?,
        errorStream: (any MSPCommandOutputStream)?
    ) -> ShellVisibleOutputStreams {
        ShellVisibleOutputStreams(
            outputStream: visibleStream(
                for: stdoutBinding,
                outputStream: outputStream,
                errorStream: errorStream
            ),
            errorStream: visibleStream(
                for: stderrBinding,
                outputStream: outputStream,
                errorStream: errorStream
            )
        )
    }

    static func emitVisibleOutput(
        _ result: MSPCommandResult,
        outputStream: (any MSPCommandOutputStream)?,
        errorStream: (any MSPCommandOutputStream)?,
        emitProbe: (String, [String: String]) -> Void
    ) async -> MSPCommandResult {
        if !result.stdoutData.isEmpty {
            emitProbe("probe_msp_emit_visible_stdout_write_before", [
                "bytes": "\(result.stdoutData.count)",
                "has_output_stream": "\(outputStream != nil)"
            ])
            try? await outputStream?.write(result.stdoutData)
            emitProbe("probe_msp_emit_visible_stdout_write_after", [
                "bytes": "\(result.stdoutData.count)",
                "has_output_stream": "\(outputStream != nil)"
            ])
        }
        if !result.stderrData.isEmpty {
            emitProbe("probe_msp_emit_visible_stderr_write_before", [
                "bytes": "\(result.stderrData.count)",
                "has_error_stream": "\(errorStream != nil)"
            ])
            try? await errorStream?.write(result.stderrData)
            emitProbe("probe_msp_emit_visible_stderr_write_after", [
                "bytes": "\(result.stderrData.count)",
                "has_error_stream": "\(errorStream != nil)"
            ])
        }
        return result
    }

    private static func visibleStream(
        for binding: MSPRedirectionOutputBinding,
        outputStream: (any MSPCommandOutputStream)?,
        errorStream: (any MSPCommandOutputStream)?
    ) -> (any MSPCommandOutputStream)? {
        switch binding {
        case .agentStdout:
            return outputStream
        case .agentStderr:
            return errorStream
        case .closed, .discard, .file, .openFileDescription:
            return nil
        }
    }
}
