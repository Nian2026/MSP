import Foundation
import MSPCore
import MSPShell

struct ShellRuntimeReentryCommandPorts {
    var runCommandLine: (RuntimeReentryCommandLineRunRequest) async -> MSPCommandResult
    var runLoadedScriptRecord: (ShellLoadedScriptRecordRunRequest) async -> MSPCommandResult
    var runCommandList: (ShellCompoundCommandListRunRequest) async -> MSPCommandResult
    var runCommandText: (ShellCompoundCommandTextRunRequest) async -> MSPCommandResult
}

struct ShellRuntimeReentryDiagnosticsPorts {
    var diagnosticReason: (Error) -> String
}

struct ShellRuntimeReentryIOPorts {
    var applyRedirections: (
        [MSPParsedRedirection],
        Data,
        Bool,
        String,
        MSPRedirectionOutputBinding?,
        MSPRedirectionOutputBinding?
    ) throws -> MSPRedirectionRouting
    var finalizeRedirections: (
        MSPRedirectionRouting,
        MSPCommandResult,
        Int
    ) async throws -> MSPCommandResult
    var remainingInputData: (Int) throws -> Data
}

struct ShellRuntimeReentryExpansionPorts {
    var expandedReadAssignmentEnvironment: (
        MSPParsedReadSpec,
        Int32,
        inout String
    ) async throws -> [MSPParsedAssignment]
    var expandWordText: (
        MSPParsedWord,
        Int32,
        Bool,
        Bool
    ) async throws -> MSPShellWordTextExpansionResult
    var expandWordVariants: (
        MSPParsedWord,
        Int32
    ) async throws -> MSPShellWordExpansionResult
}

struct ShellRuntimeReentryPorts {
    var commands: ShellRuntimeReentryCommandPorts
    var diagnostics: ShellRuntimeReentryDiagnosticsPorts
    var io: ShellRuntimeReentryIOPorts
    var expansion: ShellRuntimeReentryExpansionPorts
    var exitTrap: ShellRuntimeExitTrapPorts
}
