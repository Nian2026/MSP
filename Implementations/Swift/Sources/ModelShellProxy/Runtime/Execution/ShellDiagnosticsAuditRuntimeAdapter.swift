import Foundation
import MSPCore
import MSPShell

extension ModelShellProxy {
    private var shellDiagnostics: ShellExecutionDiagnostics {
        runtime.shellDiagnostics(configuredContext: configuredShellDiagnosticContext)
    }

    private var configuredShellDiagnosticContext: MSPShellDiagnosticContext? {
        ShellExecutionDiagnostics.configuredContext(for: configuration.shellDiagnosticProfile)
    }

    func shellFunctionSourceNameForCurrentDefinition() -> String? {
        shellDiagnostics.functionSourceNameForCurrentDefinition
    }

    func shellRedirectionFailureResult(
        _ result: MSPCommandResult,
        sourceLineNumber: Int?
    ) -> MSPCommandResult {
        shellDiagnostics.shellRedirectionFailureResult(
            result,
            sourceLineNumber: sourceLineNumber
        )
    }

    func shellCommandLookupFailureResult(
        _ result: MSPCommandResult,
        commandName: String,
        sourceLineNumber: Int?
    ) -> MSPCommandResult {
        shellDiagnostics.shellCommandLookupFailureResult(
            result,
            commandName: commandName,
            sourceLineNumber: sourceLineNumber
        )
    }

    func shellExpansionFailureResult(_ error: MSPShellExpansionError) -> MSPCommandResult {
        shellDiagnostics.shellExpansionFailureResult(error)
    }

    func recordAudit(
        commandLine: String,
        parsed: MSPParsedCommandLine,
        result: MSPCommandResult,
        startedAt: Date
    ) async {
        await ShellAuditRecorder.record(
            commandLine: commandLine,
            parsed: parsed,
            result: result,
            startedAt: startedAt,
            auditSink: configuration.auditSink
        )
    }

    func parsedCommandsAuditLine(
        parsed: MSPParsedCommandLine,
        fullCommandLine: String
    ) -> String {
        ShellAuditRecorder.parsedCommandsAuditLine(
            parsed: parsed,
            fullCommandLine: fullCommandLine
        )
    }
}
