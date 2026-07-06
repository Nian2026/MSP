import Foundation
import MSPCore

typealias RuntimeReentryCommandLineRunner = (_ request: RuntimeReentryCommandLineRunRequest) async -> MSPCommandResult
typealias RuntimeReentryScriptRunner = (_ request: RuntimeReentryScriptRunRequest) async -> MSPCommandResult

struct RuntimeReentryIO {
    var standardInput: Data
    var standardInputClosed: Bool
    var stdoutBinding: MSPRedirectionOutputBinding?
    var stderrBinding: MSPRedirectionOutputBinding?
    var lastExitCode: Int32
    var outputStream: (any MSPCommandOutputStream)?
    var errorStream: (any MSPCommandOutputStream)?
}

struct RuntimeReentryCommandLineRunRequest {
    var commandLine: String
    var io: RuntimeReentryIO
    var syntaxDiagnosticCommandName: String?
}

struct RuntimeReentryScriptRunRequest {
    var script: String
    var io: RuntimeReentryIO
}

struct RuntimeLoadedShellScriptCommandRequest {
    var scriptName: String
    var shellLauncherName: String
    var script: String
    var arguments: [String]
    var io: RuntimeReentryIO
    var syntaxCheckOnly: Bool
    var childErrexit: Bool?
    var childNounset: Bool?
    var childPipefail: Bool?
}
