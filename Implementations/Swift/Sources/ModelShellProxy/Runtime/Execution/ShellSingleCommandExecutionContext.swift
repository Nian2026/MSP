import Foundation
import MSPCore
import MSPShell

struct ShellSingleCommandExecutionContext {
    var frame: ShellExecutionFrame

    var processSubstitutionCheckpoint: () -> Int
    var cleanupProcessSubstitutionTemporaryPaths: (Int) -> Void

    var expandCommandLine: (
        MSPParsedCommandLine,
        ShellExecutionFrame
    ) async throws -> MSPShellCommandSubstitutionExpansion
    var applyExpansionState: (MSPShellCommandSubstitutionExpansion) -> Void
    var expansionFailureResult: (MSPShellExpansionError) -> MSPCommandResult
    var setPendingShellExitCode: (Int32) -> Void

    var currentDirectory: () -> String
    var evaluatePolicy: (MSPPolicyRequest) async -> MSPPolicyDecision
    var resolveVirtualExecutableCommandPath: (String) -> String?
    var commandCanRunWithPathSearch: (
        ShellCommandDispatch,
        MSPParsedCommandLine,
        Bool
    ) -> Bool
    var dispatch: (MSPParsedCommandLine) -> ShellCommandDispatch

    var recordAudit: (String, MSPParsedCommandLine, MSPCommandResult, Date) async -> Void
    var parsedCommandsAuditLine: (MSPParsedCommandLine, String) -> String
    var withCommandSubstitutionStderr: (String, MSPCommandResult) -> MSPCommandResult
    var withXtraceStderr: (String, MSPCommandResult) -> MSPCommandResult
    var xtraceDiagnostic: (MSPParsedCommandLine) -> String
    var shellRedirectionFailureResult: (MSPCommandResult, Int?) -> MSPCommandResult

    var applyRedirections: (
        [MSPParsedRedirection],
        ShellExecutionFrame
    ) throws -> MSPRedirectionRouting
    var finalizeRedirections: (
        MSPRedirectionRouting,
        MSPCommandResult,
        Int,
        String?
    ) async throws -> MSPCommandResult
    var runWithScopedFileDescriptorRouting: (
        MSPRedirectionRouting,
        Set<Int>,
        @escaping () async -> MSPCommandResult
    ) async -> MSPCommandResult
    var scopedOutputBinding: (MSPRedirectionOutputBinding) -> MSPRedirectionOutputBinding

    var handlers: ShellSingleCommandHandlers
}
