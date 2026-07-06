import Foundation
import MSPCore
import MSPShell

extension ShellSingleCommandExecutor {
    static func runScopedCommand(
        parsed: MSPParsedCommandLine,
        routing: MSPRedirectionRouting,
        touchedFileDescriptors: Set<Int>,
        context: ShellSingleCommandExecutionContext,
        operation: @escaping (
            MSPRedirectionOutputBinding?,
            MSPRedirectionOutputBinding?
        ) async -> MSPCommandResult
    ) async -> MSPCommandResult {
        let frame = context.frame
        let outputScope = IORuntimeState.redirectionOutputScope(
            for: parsed.redirections,
            stdoutBindingOverride: frame.stdoutBindingOverride,
            stderrBindingOverride: frame.stderrBindingOverride
        )
        return await context.runWithScopedFileDescriptorRouting(
            routing,
            touchedFileDescriptors
        ) {
            await operation(
                outputScope.stdout ? context.scopedOutputBinding(routing.stdoutBinding) : nil,
                outputScope.stderr ? context.scopedOutputBinding(routing.stderrBinding) : nil
            )
        }
    }

    static func finalizeAndAudit(
        _ result: MSPCommandResult,
        parsed: MSPParsedCommandLine,
        fullCommandLine: String,
        commandSubstitutionStderr: String,
        routing: MSPRedirectionRouting,
        processSubstitutionStartIndex: Int,
        startedAt: Date,
        xtraceStderr: String = "",
        mapsRedirectionFailureToShellDiagnostic: Bool = false,
        context: ShellSingleCommandExecutionContext
    ) async -> MSPCommandResult {
        var result = await finalizedResult(
            result,
            parsed: parsed,
            routing: routing,
            processSubstitutionStartIndex: processSubstitutionStartIndex,
            mapsRedirectionFailureToShellDiagnostic: mapsRedirectionFailureToShellDiagnostic,
            context: context
        )
        result = context.withXtraceStderr(xtraceStderr, result)
        result = context.withCommandSubstitutionStderr(commandSubstitutionStderr, result)
        await recordParsedCommandAudit(
            parsed: parsed,
            fullCommandLine: fullCommandLine,
            result: result,
            startedAt: startedAt,
            context: context
        )
        return result
    }

    static func finalizedResult(
        _ result: MSPCommandResult,
        parsed: MSPParsedCommandLine,
        routing: MSPRedirectionRouting,
        processSubstitutionStartIndex: Int,
        commandNameForFinalize: String? = nil,
        mapsRedirectionFailureToShellDiagnostic: Bool = false,
        context: ShellSingleCommandExecutionContext
    ) async -> MSPCommandResult {
        do {
            return try await context.finalizeRedirections(
                routing,
                result,
                processSubstitutionStartIndex,
                commandNameForFinalize
            )
        } catch let failure as MSPCommandFailure {
            return mapsRedirectionFailureToShellDiagnostic
                ? context.shellRedirectionFailureResult(failure.result, context.frame.sourceLineNumber)
                : failure.result
        } catch {
            return MSPCommandResult.failure(exitCode: 1, stderr: "\(parsed.commandName): \(error)\n")
        }
    }

    static func recordParsedCommandAudit(
        parsed: MSPParsedCommandLine,
        fullCommandLine: String,
        result: MSPCommandResult,
        startedAt: Date,
        context: ShellSingleCommandExecutionContext
    ) async {
        await context.recordAudit(
            context.parsedCommandsAuditLine(parsed, fullCommandLine),
            parsed,
            result,
            startedAt
        )
    }
}
