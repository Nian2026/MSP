import Foundation
import MSPCore
import MSPShell

struct ShellSingleCommandHandlers {
    var preRedirection: ShellSingleCommandPreRedirectionHandlers
    var builtins: ShellSingleCommandBuiltinHandlers
    var reentry: ShellSingleCommandReentryHandlers
    var registry: ShellSingleCommandRegistryHandlers
}

struct ShellSingleCommandPreRedirectionHandlers {
    var storeFunctionDefinition: (MSPParsedFunctionDefinition, Bool) -> Void
    var persistentOutputProcessSubstitutionPaths: () -> Set<String>
    var executeExecCommand: ([String], [MSPParsedRedirection], Bool) -> MSPCommandResult
    var appendClosedPersistentOutputProcessSubstitutions: (
        Set<String>,
        MSPCommandResult
    ) async throws -> MSPCommandResult
}

struct ShellSingleCommandBuiltinHandlers {
    var executeReturnCommand: ([String], Int32) -> MSPCommandResult
    var executeLoopControlCommand: (String, [String], Bool) -> MSPCommandResult
    var executeExitCommand: ([String], Int32, Bool) -> MSPCommandResult
    var executeShiftCommand: ([String], Bool) -> MSPCommandResult
    var executeSetCommand: ([String], Bool) -> MSPCommandResult
    var executeShoptCommand: ([String], Bool) -> MSPCommandResult
    var executeDeclareCommand: (String, [String], Bool) -> MSPCommandResult
    var executeVariableAttributeCommand: (String, [String], Bool) -> MSPCommandResult
    var executeAliasCommand: (String, [String], Bool) -> MSPCommandResult
    var executeTrapCommand: ([String], Bool) -> MSPCommandResult
    var executeUmaskCommand: ([String], Bool) -> MSPCommandResult
    var executeUnsetCommand: ([String], Bool) -> MSPCommandResult
    var executeLocalCommand: ([String], Bool) -> MSPCommandResult
    var executeReadCommand: (
        [String],
        MSPRedirectionRouting,
        [MSPParsedAssignment],
        Bool
    ) async -> MSPCommandResult
    var executeMapfileCommand: (
        String,
        [String],
        MSPRedirectionRouting,
        Bool
    ) async -> MSPCommandResult
    var executeArithmeticCommand: (String, Bool) -> MSPCommandResult
    var applyAssignmentOnlyStateChange: (MSPParsedCommandLine) -> Void
    var executeDoubleBracketRegexCommand: ([String], Bool) -> MSPCommandResult
}

struct ShellSingleCommandReentryIO {
    var standardInput: Data
    var standardInputClosed: Bool
    var stdoutBinding: MSPRedirectionOutputBinding?
    var stderrBinding: MSPRedirectionOutputBinding?
    var lastExitCode: Int32
    var outputStream: (any MSPCommandOutputStream)?
    var errorStream: (any MSPCommandOutputStream)?
}

struct ShellSingleCommandEvalRequest {
    var arguments: [String]
    var io: ShellSingleCommandReentryIO
    var appliesStateChange: Bool
    var hasInputRedirection: Bool
}

struct ShellSingleCommandSourceRequest {
    var commandName: String
    var arguments: [String]
    var io: ShellSingleCommandReentryIO
    var appliesStateChange: Bool
}

struct ShellSingleCommandShellLauncherRequest {
    var commandName: String
    var shellLauncherName: String
    var arguments: [String]
    var io: ShellSingleCommandReentryIO
}

struct ShellSingleCommandCompoundRequest {
    var compoundCommand: MSPParsedStructuredCompoundCommand
    var io: ShellSingleCommandReentryIO
    var appliesStateChange: Bool
    var sourceLineNumber: Int?
}

struct ShellSingleCommandFunctionRequest {
    var functionDefinition: MSPParsedFunctionDefinition
    var diagnosticSourceName: String?
    var arguments: [String]
    var assignments: [MSPParsedAssignment]
    var io: ShellSingleCommandReentryIO
}

struct ShellSingleCommandPathScriptRequest {
    var commandName: String
    var arguments: [String]
    var io: ShellSingleCommandReentryIO
    var sourceLineNumber: Int?
}

struct ShellSingleCommandReentryHandlers {
    var executeEvalCommand: (ShellSingleCommandEvalRequest) async -> MSPCommandResult
    var executeSourceCommand: (ShellSingleCommandSourceRequest) async -> MSPCommandResult
    var executeShellLauncherCommand: (ShellSingleCommandShellLauncherRequest) async -> MSPCommandResult
    var runCompoundCommand: (ShellSingleCommandCompoundRequest) async -> MSPCommandResult
    var saveShellRuntimeState: () -> ShellRuntimeState
    var restoreShellRuntimeState: (ShellRuntimeState) -> Void
    var executeShellFunction: (ShellSingleCommandFunctionRequest) async -> MSPCommandResult
    var executePathScriptCommand: (ShellSingleCommandPathScriptRequest) async -> MSPCommandResult
}

struct ShellSingleCommandRegistryHandlers {
    var executeRegistryCommand: (
        MSPParsedCommandLine,
        MSPRedirectionRouting
    ) async -> MSPCommandResult
    var shellCommandLookupFailureResult: (MSPCommandResult, String, Int?) -> MSPCommandResult
    var applyCommandStateChange: (MSPCommandRuntimeStateChange?) -> Void
}
