import MSPShell

struct ShellRuntimeMutableState {
    var shellFunctions: [String: MSPParsedFunctionDefinition] = [:]
    var shellFunctionSourceNames: [String: String] = [:]
    var functionDepth = 0
    var functionLocalEnvironmentStack: [[String: MSPShellLocalVariableSnapshot]] = []
    var sourceDepth = 0
    var loopDepth = 0
    var positionalParameters = ["msp"]
    var pendingFunctionReturnCode: Int32?
    var pendingLoopControl: MSPShellLoopControl?
    var pendingShellExitCode: Int32?
    var shellOptions: Set<String> = []
    var shellArrays: [String: MSPShellIndexedArray] = [:]
    var shellAssociativeArrays: [String: [String: String]] = [:]
    var shellNamerefs: [String: String] = [:]
    var shellAliases: [String: String] = [:]
    var exportedVariableNames: Set<String> = []
    var readonlyVariableNames: Set<String> = []
    var shellTraps: [String: String] = [:]
    var runningTraps: Set<String> = []
    var isErrexitEnabled = false
    var isNounsetEnabled = false
    var isPipefailEnabled = false
    var isXtraceEnabled = false
    var enablesBashParameterExtensions = true
    var shellDiagnosticContextStack: [MSPShellDiagnosticContext] = []

    mutating func seedExportedVariables(from environment: [String: String]) {
        exportedVariableNames = Set(environment.keys).union(["OLDPWD"])
    }
}
