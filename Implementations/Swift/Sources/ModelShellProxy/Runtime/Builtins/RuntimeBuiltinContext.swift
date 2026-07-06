import MSPCore
import MSPShell

struct RuntimeBuiltinContext {
    var configuration: MSPConfiguration
    var shellFunctions: [String: MSPParsedFunctionDefinition]
    var shellFunctionSourceNames: [String: String]
    var functionDepth: Int
    var sourceDepth: Int
    var loopDepth: Int
    var functionLocalEnvironmentStack: [[String: MSPShellLocalVariableSnapshot]]
    var positionalParameters: [String]
    var pendingFunctionReturnCode: Int32?
    var pendingLoopControl: MSPShellLoopControl?
    var pendingShellExitCode: Int32?
    var shellOptions: Set<String>
    var shellArrays: [String: MSPShellIndexedArray]
    var shellAssociativeArrays: [String: [String: String]]
    var shellNamerefs: [String: String]
    var shellAliases: [String: String]
    var shellDiagnosticContextStack: [MSPShellDiagnosticContext]
    var exportedVariableNames: Set<String>
    var readonlyVariableNames: Set<String>
    var shellTraps: [String: String]
    var isErrexitEnabled: Bool
    var isNounsetEnabled: Bool
    var isPipefailEnabled: Bool
    var isXtraceEnabled: Bool
    var enablesBashParameterExtensions: Bool
    var diagnostics: ShellExecutionDiagnostics {
        ShellExecutionDiagnostics(
            contextStack: shellDiagnosticContextStack,
            configuredContext: ShellExecutionDiagnostics.configuredContext(
                for: configuration.shellDiagnosticProfile
            )
        )
    }
}
