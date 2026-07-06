import Foundation
import MSPCore
import MSPShell

struct ShellCommandListRunnerContext {
    var initialLastExitCode: Int32
    var clearsShellControlAtEnd: Bool
    var suppressesErrexit: Bool
    var sourceLineOffset: Int
    var syntaxDiagnosticCommandName: String?
    var outputStream: (any MSPCommandOutputStream)?
    var errorStream: (any MSPCommandOutputStream)?
    var parsePipelines: (String) throws -> [MSPParsedCommandPipeline]
    var parserSyntaxFailureResult: (Int32, String, Int, String?, String) -> MSPCommandResult
    var runPipeline: (
        MSPParsedCommandPipeline,
        String,
        Int32,
        Int?,
        (any MSPCommandOutputStream)?,
        (any MSPCommandOutputStream)?
    ) async -> MSPCommandResult
    var hasPendingShellControl: () -> Bool
    var consumePendingShellExitCode: () -> Int32?
    var clearPendingLoopControl: () -> Void
    var runExitTrap: (Int32) async -> MSPCommandResult?
    var isErrexitEnabled: () -> Bool
}

enum ShellCommandListRunner {
    static func runCommandLine(
        _ commandLine: String,
        context: ShellCommandListRunnerContext
    ) async -> MSPCommandResult {
        let parsedPipelines: [MSPParsedCommandPipeline]
        do {
            parsedPipelines = try context.parsePipelines(commandLine)
        } catch MSPShellParserError.emptyInput {
            return .success()
        } catch MSPShellParserError.syntax(let exitCode, let message) {
            let diagnosticLineNumber = shellSyntaxDiagnosticLineNumber(
                message: message,
                commandLine: commandLine,
                sourceLineOffset: context.sourceLineOffset
            )
            return context.parserSyntaxFailureResult(
                Int32(exitCode),
                message,
                diagnosticLineNumber,
                context.syntaxDiagnosticCommandName,
                commandLine
            )
        } catch MSPShellParserError.unsupportedExecutionForm(let message) {
            return .failure(exitCode: 2, stderr: message.hasSuffix("\n") ? message : message + "\n")
        } catch {
            return .failure(exitCode: 2, stderr: "\(error)\n")
        }

        return await run(
            MSPParsedCommandList(pipelines: parsedPipelines, rawInput: commandLine),
            context: context
        )
    }

    static func run(
        _ commandList: MSPParsedCommandList,
        context: ShellCommandListRunnerContext
    ) async -> MSPCommandResult {
        let parsedPipelines = commandList.pipelines
        let commandLine = commandList.rawInput
        guard !parsedPipelines.isEmpty else {
            return .success()
        }

        var stdoutData = Data()
        var stderrData = Data()
        var modelContentItems: [MSPCommandModelContentItem] = []
        var exitCode = context.initialLastExitCode
        var lineSearchStart = commandLine.startIndex
        for index in parsedPipelines.indices {
            let parsed = parsedPipelines[index]
            switch parsed.leadingOperator {
            case nil, .semicolon?:
                break
            case .and? where exitCode == 0:
                break
            case .or? where exitCode != 0:
                break
            case .and?, .or?:
                continue
            }
            let sourceLineNumber = lineNumber(
                for: parsed.rawInput,
                in: commandLine,
                searchStart: &lineSearchStart,
                sourceLineOffset: context.sourceLineOffset
            )
            let result = await context.runPipeline(
                parsed,
                commandLine,
                exitCode,
                sourceLineNumber,
                context.outputStream,
                context.errorStream
            )
            stdoutData.append(result.stdoutData)
            stderrData.append(result.stderrData)
            modelContentItems.append(contentsOf: result.modelContentItems)
            exitCode = result.exitCode
            if context.hasPendingShellControl() {
                break
            }
            let nextOperator = parsedPipelines.indices.contains(index + 1)
                ? parsedPipelines[index + 1].leadingOperator
                : nil
            if shouldStopForErrexit(
                result,
                pipeline: parsed,
                nextOperator: nextOperator,
                context: context
            ) {
                break
            }
        }
        if context.clearsShellControlAtEnd {
            if let shellExitCode = context.consumePendingShellExitCode() {
                exitCode = shellExitCode
            }
            context.clearPendingLoopControl()
        }
        if context.clearsShellControlAtEnd,
           let trapResult = await context.runExitTrap(exitCode) {
            stdoutData.append(trapResult.stdoutData)
            stderrData.append(trapResult.stderrData)
            modelContentItems.append(contentsOf: trapResult.modelContentItems)
            exitCode = trapResult.exitCode
        }
        return MSPCommandResult(
            stdoutData: stdoutData,
            stderrData: stderrData,
            exitCode: exitCode,
            modelContentItems: modelContentItems
        )
    }

    private static func shouldStopForErrexit(
        _ result: MSPCommandResult,
        pipeline: MSPParsedCommandPipeline,
        nextOperator: MSPParsedListOperator?,
        context: ShellCommandListRunnerContext
    ) -> Bool {
        guard context.isErrexitEnabled(),
              !context.suppressesErrexit,
              result.exitCode != 0,
              !pipeline.isNegated else {
            return false
        }
        switch nextOperator {
        case .and?, .or?:
            return false
        case .semicolon?, nil:
            return true
        }
    }

    private static func shellSyntaxDiagnosticLineNumber(
        message: String,
        commandLine: String,
        sourceLineOffset: Int
    ) -> Int {
        ShellExecutionDiagnostics.shellSyntaxDiagnosticLineNumber(
            message: message,
            commandLine: commandLine,
            sourceLineOffset: sourceLineOffset
        )
    }

    private static func lineNumber(
        for rawInput: String,
        in commandLine: String,
        searchStart: inout String.Index,
        sourceLineOffset: Int
    ) -> Int {
        let candidates = [
            rawInput,
            rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        ].filter { !$0.isEmpty }

        for candidate in candidates {
            if let range = commandLine.range(of: candidate, range: searchStart..<commandLine.endIndex) {
                searchStart = range.upperBound
                return sourceLineOffset + lineNumber(at: range.lowerBound, in: commandLine)
            }
        }
        return sourceLineOffset + 1
    }

    private static func lineNumber(at index: String.Index, in text: String) -> Int {
        var line = 1
        var cursor = text.startIndex
        while cursor < index {
            if text[cursor] == "\n" {
                line += 1
            }
            cursor = text.index(after: cursor)
        }
        return line
    }
}
