import MSPShell

struct ShellRuntimeState {
    var configuration: MSPConfiguration
    var shellFunctions: [String: MSPParsedFunctionDefinition]
    var shellFunctionSourceNames: [String: String]
    var functionDepth: Int
    var loopDepth: Int
    var functionLocalEnvironmentStack: [[String: MSPShellLocalVariableSnapshot]]
    var sourceDepth: Int
    var positionalParameters: [String]
    var pendingFunctionReturnCode: Int32?
    var pendingLoopControl: MSPShellLoopControl?
    var pendingShellExitCode: Int32?
    var io: IORuntimeState
    var shellOptions: Set<String>
    var shellArrays: [String: MSPShellIndexedArray]
    var shellAssociativeArrays: [String: [String: String]]
    var shellNamerefs: [String: String]
    var shellAliases: [String: String]
    var exportedVariableNames: Set<String>
    var readonlyVariableNames: Set<String>
    var shellTraps: [String: String]
    var runningTraps: Set<String>
    var isErrexitEnabled: Bool
    var isNounsetEnabled: Bool
    var isPipefailEnabled: Bool
    var isXtraceEnabled: Bool
    var enablesBashParameterExtensions: Bool
    var shellDiagnosticContextStack: [MSPShellDiagnosticContext]
}

struct ShellCommandLineRunnerState {
    var configuration: MSPConfiguration
    var exportedVariableNames: Set<String>
}

struct MSPShellLocalVariableSnapshot {
    var environment: String?
    var array: MSPShellIndexedArray?
    var associativeArray: [String: String]?
    var nameref: String?
    var wasExported: Bool
    var wasReadonly: Bool
}

enum MSPShellLoopControl: Equatable {
    case breakLoop(Int)
    case continueLoop(Int)
}
