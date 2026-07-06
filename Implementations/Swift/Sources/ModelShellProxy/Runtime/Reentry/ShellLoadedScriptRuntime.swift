import Foundation
import MSPCore
import MSPShell

struct ShellLoadedScriptRecordRunRequest {
    var commandText: String
    var initialLastExitCode: Int32
    var sourceLineOffset: Int
    var outputStream: (any MSPCommandOutputStream)?
    var errorStream: (any MSPCommandOutputStream)?
}

struct ShellLoadedScriptRuntimeContext {
    var parser: MSPShellParser
    var shellOptions: () -> Set<String>
    var hasPendingShellControl: () -> Bool
    var isErrexitEnabled: () -> Bool
    var pendingShellExitCode: () -> Int32?
    var setPendingShellExitCode: (Int32?) -> Void
    var clearPendingLoopControl: () -> Void
    var runCommandText: (ShellLoadedScriptRecordRunRequest) async -> MSPCommandResult
    var runExitTrapIfNeeded: (Int32) async -> MSPCommandResult?
}

struct ShellLoadedScriptRuntime {
    var context: ShellLoadedScriptRuntimeContext

    func runIncrementally(
        _ script: String,
        initialLastExitCode: Int32,
        outputStream: (any MSPCommandOutputStream)?,
        errorStream: (any MSPCommandOutputStream)?
    ) async -> MSPCommandResult {
        var stdoutData = Data()
        var stderrData = Data()
        var modelContentItems: [MSPCommandModelContentItem] = []
        var exitCode = initialLastExitCode
        var buffer = ""
        var bufferStartLine = 1
        var currentLine = 1
        var shouldStopScript = false

        let lines = script.split(separator: "\n", omittingEmptySubsequences: false)
        for index in lines.indices {
            if buffer.isEmpty {
                bufferStartLine = currentLine
            }
            buffer += String(lines[index])
            if index != lines.indices.last || script.hasSuffix("\n") {
                buffer += "\n"
            }

            switch shellScriptRecordState(buffer) {
            case .empty:
                buffer.removeAll(keepingCapacity: true)
            case .incomplete:
                break
            case .complete:
                let result = await runRecord(
                    buffer,
                    initialLastExitCode: exitCode,
                    sourceLineOffset: max(0, bufferStartLine - 1),
                    outputStream: outputStream,
                    errorStream: errorStream
                )
                stdoutData.append(result.stdoutData)
                stderrData.append(result.stderrData)
                modelContentItems.append(contentsOf: result.modelContentItems)
                exitCode = result.exitCode
                buffer.removeAll(keepingCapacity: true)
            case .syntax:
                let result = await runRecord(
                    buffer,
                    initialLastExitCode: exitCode,
                    sourceLineOffset: max(0, bufferStartLine - 1),
                    outputStream: outputStream,
                    errorStream: errorStream
                )
                stdoutData.append(result.stdoutData)
                stderrData.append(result.stderrData)
                modelContentItems.append(contentsOf: result.modelContentItems)
                exitCode = result.exitCode
                buffer.removeAll(keepingCapacity: true)
                shouldStopScript = true
            }

            if shouldStopScript || context.hasPendingShellControl() || context.isErrexitEnabled() && exitCode != 0 {
                break
            }
            currentLine += 1
        }

        if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !context.hasPendingShellControl() {
            let result = await runRecord(
                buffer,
                initialLastExitCode: exitCode,
                sourceLineOffset: max(0, bufferStartLine - 1),
                outputStream: outputStream,
                errorStream: errorStream
            )
            stdoutData.append(result.stdoutData)
            stderrData.append(result.stderrData)
            modelContentItems.append(contentsOf: result.modelContentItems)
            exitCode = result.exitCode
        }

        if let shellExitCode = context.pendingShellExitCode() {
            exitCode = shellExitCode
            context.setPendingShellExitCode(nil)
        }
        context.clearPendingLoopControl()
        if let trapResult = await context.runExitTrapIfNeeded(exitCode) {
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

    private func runRecord(
        _ commandText: String,
        initialLastExitCode: Int32,
        sourceLineOffset: Int,
        outputStream: (any MSPCommandOutputStream)?,
        errorStream: (any MSPCommandOutputStream)?
    ) async -> MSPCommandResult {
        await context.runCommandText(
            ShellLoadedScriptRecordRunRequest(
                commandText: commandText,
                initialLastExitCode: initialLastExitCode,
                sourceLineOffset: sourceLineOffset,
                outputStream: outputStream,
                errorStream: errorStream
            )
        )
    }

    private func shellScriptRecordState(_ text: String) -> ShellScriptRecordState {
        if shellScriptHasUnterminatedHereDocument(text) {
            return .incomplete
        }
        do {
            _ = try context.parser.parseExecutablePipelines(
                text,
                enablesExtendedGlob: context.shellOptions().contains("extglob")
            )
            return .complete
        } catch MSPShellParserError.emptyInput {
            return .empty
        } catch MSPShellParserError.syntax(_, let message)
            where ShellExecutionDiagnostics.isParserUnexpectedEOFDiagnostic(message) {
            return .incomplete
        } catch {
            return .syntax
        }
    }

    private func shellScriptHasUnterminatedHereDocument(_ text: String) -> Bool {
        var pendingDelimiters: [(delimiter: String, stripsTabs: Bool)] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for index in lines.indices {
            let line = lines[index]
            if !pendingDelimiters.isEmpty {
                let pending = pendingDelimiters[0]
                let candidate = pending.stripsTabs
                    ? String(line.drop { $0 == "\t" })
                    : line
                if candidate == pending.delimiter {
                    pendingDelimiters.removeFirst()
                }
                continue
            }
            if index == lines.indices.last, !text.hasSuffix("\n") {
                pendingDelimiters.append(contentsOf: shellHereDocumentDelimiters(in: line))
                continue
            }
            pendingDelimiters.append(contentsOf: shellHereDocumentDelimiters(in: line))
        }
        return !pendingDelimiters.isEmpty
    }

    private func shellHereDocumentDelimiters(in line: String) -> [(delimiter: String, stripsTabs: Bool)] {
        let characters = Array(line)
        var delimiters: [(delimiter: String, stripsTabs: Bool)] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "'" || character == "\"" {
                let quote = character
                index += 1
                while index < characters.count, characters[index] != quote {
                    index += 1
                }
                index += 1
                continue
            }
            guard character == "<",
                  index + 1 < characters.count,
                  characters[index + 1] == "<",
                  !(index + 2 < characters.count && characters[index + 2] == "<")
            else {
                index += 1
                continue
            }
            index += 2
            var stripsTabs = false
            if index < characters.count, characters[index] == "-" {
                stripsTabs = true
                index += 1
            }
            while index < characters.count, characters[index].isWhitespace {
                index += 1
            }
            let delimiter = shellHereDocumentDelimiter(in: characters, startingAt: &index)
            if !delimiter.isEmpty {
                delimiters.append((delimiter, stripsTabs))
            }
        }
        return delimiters
    }

    private func shellHereDocumentDelimiter(in characters: [Character], startingAt index: inout Int) -> String {
        guard index < characters.count else {
            return ""
        }
        var delimiter = ""
        if characters[index] == "'" || characters[index] == "\"" {
            let quote = characters[index]
            index += 1
            while index < characters.count, characters[index] != quote {
                delimiter.append(characters[index])
                index += 1
            }
            if index < characters.count {
                index += 1
            }
            return delimiter
        }
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace || ";|&<>()".contains(character) {
                break
            }
            delimiter.append(character)
            index += 1
        }
        return delimiter
    }
}

private enum ShellScriptRecordState {
    case empty
    case incomplete
    case complete
    case syntax
}
