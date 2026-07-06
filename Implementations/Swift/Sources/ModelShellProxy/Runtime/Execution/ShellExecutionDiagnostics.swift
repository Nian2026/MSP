import Foundation
import MSPCore
import MSPShell

struct ShellExecutionDiagnostics {
    var contextStack: [MSPShellDiagnosticContext]
    var configuredContext: MSPShellDiagnosticContext?

    var currentContext: MSPShellDiagnosticContext? {
        contextStack.last ?? configuredContext
    }

    var functionSourceNameForCurrentDefinition: String? {
        if let sourceContext = contextStack.last {
            return sourceContext.scriptName
        }
        return configuredContext == nil ? nil : "environment"
    }

    static func configuredContext(for profile: MSPShellDiagnosticProfile?) -> MSPShellDiagnosticContext? {
        guard let profile else {
            return nil
        }
        switch profile {
        case .bash(let scriptName):
            return MSPShellDiagnosticContext(scriptName: scriptName, style: .bash)
        case .dash(let scriptName):
            return MSPShellDiagnosticContext(scriptName: scriptName, style: .dash)
        }
    }

    func parserSyntaxFailureResult(
        exitCode: Int32,
        message: String,
        lineNumber: Int,
        commandName: String?,
        commandLine: String
    ) -> MSPCommandResult {
        guard let context = currentContext else {
            return .failure(exitCode: exitCode, stderr: message.hasSuffix("\n") ? message : message + "\n")
        }
        let diagnosticMessage = Self.shellSyntaxDiagnosticMessage(
            message,
            commandName: commandName,
            style: context.style
        )
        let effectiveLineNumber: Int
        if context.style == .dash,
           commandName == "eval",
           message == "if: missing fi" {
            effectiveLineNumber = 1
        } else {
            effectiveLineNumber = lineNumber
        }
        if contextStack.isEmpty,
           commandName == nil,
           context.style == .bash,
           Self.shellParserDiagnosticEchoesCommandLine(message) {
            let line = max(1, effectiveLineNumber)
            let prefix = "\(context.scriptName): -c: line \(line): "
            return .failure(
                exitCode: exitCode,
                stderr: prefix + diagnosticMessage + "\n"
                    + prefix + "`\(commandLine)'\n"
            )
        }
        return .failure(
            exitCode: exitCode,
            stderr: diagnostic(diagnosticMessage, lineNumber: effectiveLineNumber)
        )
    }

    static func shellSyntaxDiagnosticLineNumber(
        message: String,
        commandLine: String,
        sourceLineOffset: Int
    ) -> Int {
        guard isParserUnexpectedEOFDiagnostic(message) else {
            return sourceLineOffset + 1
        }
        return sourceLineOffset + shellEOFLineNumber(in: commandLine)
    }

    func shellRedirectionFailureResult(
        _ result: MSPCommandResult,
        sourceLineNumber: Int?
    ) -> MSPCommandResult {
        guard let context = currentContext,
              result.stderr.hasPrefix("shell: ") else {
            return result
        }
        let message = String(result.stderr.dropFirst("shell: ".count))
            .trimmingCharacters(in: .newlines)
        let diagnosticMessage = Self.shellRedirectionDiagnosticMessage(
            message,
            style: context.style
        )
        return MSPCommandResult(
            stdoutData: result.stdoutData,
            stderr: diagnostic(diagnosticMessage, lineNumber: sourceLineNumber),
            exitCode: context.style == .dash ? 2 : result.exitCode,
            stateChange: result.stateChange
        )
    }

    func shellCommandLookupFailureResult(
        _ result: MSPCommandResult,
        commandName: String,
        sourceLineNumber: Int?
    ) -> MSPCommandResult {
        guard currentContext != nil,
              result.exitCode == 127,
              result.stderr == "\(commandName): command not found\n" else {
            return result
        }
        return MSPCommandResult(
            stdoutData: result.stdoutData,
            stderr: diagnostic("\(commandName): command not found", lineNumber: sourceLineNumber),
            exitCode: result.exitCode,
            stateChange: result.stateChange,
            modelContentItems: result.modelContentItems
        )
    }

    func diagnostic(_ message: String, lineNumber: Int?) -> String {
        guard let context = currentContext else {
            return message.hasSuffix("\n") ? message : message + "\n"
        }
        let line = max(1, lineNumber ?? 1)
        switch context.style {
        case .bash:
            return "\(context.scriptName): line \(line): \(message)\n"
        case .dash:
            return "\(context.scriptName): \(line): \(message)\n"
        }
    }

    func shellBuiltinDiagnosticResult(_ result: MSPCommandResult) -> MSPCommandResult {
        guard currentContext != nil,
              let firstNewline = result.stderr.firstIndex(of: "\n") else {
            return result
        }
        let firstLine = String(result.stderr[..<firstNewline])
        let remainder = String(result.stderr[result.stderr.index(after: firstNewline)...])
        return MSPCommandResult(
            stdoutData: result.stdoutData,
            stderr: diagnostic(firstLine, lineNumber: nil) + remainder,
            exitCode: result.exitCode,
            stateChange: result.stateChange,
            modelContentItems: result.modelContentItems
        )
    }

    func shellExpansionFailureResult(_ error: MSPShellExpansionError) -> MSPCommandResult {
        var message = String(describing: error)
        if message.hasPrefix("bash: ") {
            message = String(message.dropFirst("bash: ".count))
        }
        let exitCode: Int32 = message.contains("unbound variable") ? 127 : 1
        return .failure(exitCode: exitCode, stderr: diagnostic(message, lineNumber: nil))
    }

    static func dashShellDiagnosticResult(
        _ result: MSPCommandResult,
        scriptName: String
    ) -> MSPCommandResult {
        guard result.exitCode != 0,
              result.stderr.lowercased().contains("bad substitution") else {
            return result
        }
        return MSPCommandResult(
            stdoutData: result.stdoutData,
            stderr: "\(scriptName): 1: Bad substitution\n",
            exitCode: 2,
            stateChange: result.stateChange,
            modelContentItems: result.modelContentItems
        )
    }

    static func xtraceDiagnostic(
        for parsed: MSPParsedCommandLine,
        isEnabled: Bool
    ) -> String {
        guard isEnabled, !parsed.commandName.isEmpty else {
            return ""
        }
        let words = [parsed.commandName] + parsed.arguments
        return "+ " + words.joined(separator: " ") + "\n"
    }

    static func prependingXtraceStderr(
        _ xtraceStderr: String,
        to result: MSPCommandResult
    ) -> MSPCommandResult {
        guard !xtraceStderr.isEmpty else {
            return result
        }
        var stderrData = Data(xtraceStderr.utf8)
        stderrData.append(result.stderrData)
        return MSPCommandResult(
            stdoutData: result.stdoutData,
            stderrData: stderrData,
            exitCode: result.exitCode,
            stateChange: result.stateChange,
            modelContentItems: result.modelContentItems
        )
    }

    static func prependingCommandSubstitutionStderr(
        _ stderr: String,
        to result: MSPCommandResult
    ) -> MSPCommandResult {
        guard !stderr.isEmpty else {
            return result
        }
        var updated = result
        updated.stderr = stderr + updated.stderr
        return updated
    }

    private static func shellSyntaxDiagnosticMessage(
        _ message: String,
        commandName: String?,
        style: MSPShellDiagnosticStyle
    ) -> String {
        if style == .bash, isParserUnexpectedEOFDiagnostic(message) {
            return "syntax error: unexpected end of file"
        }
        if style == .bash, message == "syntax error near unexpected (" {
            return "syntax error near unexpected token `('"
        }
        if style == .bash, message == "syntax error near unexpected )" {
            return "syntax error near unexpected token `)'"
        }
        if style == .dash,
           commandName == "eval",
           message == "if: missing fi" {
            return "eval: Syntax error: \"then\" unexpected"
        }
        if let commandName {
            return "\(commandName): \(message)"
        }
        return message
    }

    private static func shellParserDiagnosticEchoesCommandLine(_ message: String) -> Bool {
        message.hasPrefix("syntax error near unexpected")
            && !isParserUnexpectedEOFDiagnostic(message)
    }

    static func isParserUnexpectedEOFDiagnostic(_ message: String) -> Bool {
        message.contains("unterminated")
            || message == "if: missing fi"
            || message == "while: missing done"
            || message == "until: missing done"
            || message == "for: missing done"
            || message == "case: missing esac"
            || message == "syntax error: missing }"
            || message == "syntax error: missing )"
    }

    private static func shellEOFLineNumber(in commandLine: String) -> Int {
        let newlineCount = commandLine.reduce(0) { count, character in
            count + (character == "\n" ? 1 : 0)
        }
        return commandLine.hasSuffix("\n") ? newlineCount + 1 : newlineCount + 2
    }

    private static func shellRedirectionDiagnosticMessage(
        _ message: String,
        style: MSPShellDiagnosticStyle
    ) -> String {
        guard style == .dash else {
            return message
        }
        let notFoundSuffix = ": No such file or directory"
        if message.hasSuffix(notFoundSuffix) {
            let path = String(message.dropLast(notFoundSuffix.count))
            return "cannot create \(path): Directory nonexistent"
        }
        return message
    }
}

struct ShellAuditRecorder {
    static func record(
        commandLine: String,
        parsed: MSPParsedCommandLine,
        result: MSPCommandResult,
        startedAt: Date,
        auditSink: any MSPAuditSink
    ) async {
        let endedAt = Date()
        await auditSink.record(
            MSPCommandRunRecord(
                commandLine: commandLine,
                commandName: parsed.commandName,
                arguments: parsed.arguments,
                exitCode: result.exitCode,
                startedAt: startedAt,
                endedAt: endedAt
            )
        )
    }

    static func parsedCommandsAuditLine(
        parsed: MSPParsedCommandLine,
        fullCommandLine: String
    ) -> String {
        parsed.rawInput.isEmpty ? fullCommandLine : parsed.rawInput
    }
}
