import Foundation
import MSPCore
import MSPShell

enum ShellCompoundLoopControlAction {
    case breakLoop
    case continueLoop
    case propagate
}

extension ShellCompoundFunctionRuntime {
    var hasPendingShellControl: Bool {
        context.pendingFunctionReturnCode() != nil
            || context.pendingLoopControl() != nil
            || context.pendingShellExitCode() != nil
    }

    func consumeLoopControlForCurrentLoop() -> ShellCompoundLoopControlAction? {
        guard let control = context.pendingLoopControl() else {
            return nil
        }

        switch control {
        case .breakLoop(let count):
            if count > 1, context.loopDepth() > 1 {
                context.setPendingLoopControl(.breakLoop(count - 1))
                return .propagate
            }
            context.setPendingLoopControl(nil)
            return .breakLoop
        case .continueLoop(let count):
            if count > 1, context.loopDepth() > 1 {
                context.setPendingLoopControl(.continueLoop(count - 1))
                return .propagate
            }
            context.setPendingLoopControl(nil)
            return .continueLoop
        }
    }

    func runCommandList(
        _ commandList: MSPParsedCommandList,
        initialLastExitCode: Int32,
        sourceLineOffset: Int = 0,
        suppressesErrexit: Bool = false,
        outputStream: (any MSPCommandOutputStream)?,
        errorStream: (any MSPCommandOutputStream)?
    ) async -> MSPCommandResult {
        await context.runCommandList(
            ShellCompoundCommandListRunRequest(
                commandList: commandList,
                initialLastExitCode: initialLastExitCode,
                sourceLineOffset: sourceLineOffset,
                suppressesErrexit: suppressesErrexit,
                outputStream: outputStream,
                errorStream: errorStream
            )
        )
    }

    func runCommandText(
        _ commandText: String,
        initialLastExitCode: Int32,
        sourceLineOffset: Int = 0,
        suppressesErrexit: Bool = false,
        outputStream: (any MSPCommandOutputStream)?,
        errorStream: (any MSPCommandOutputStream)?
    ) async -> MSPCommandResult {
        await context.runCommandText(
            ShellCompoundCommandTextRunRequest(
                commandText: commandText,
                initialLastExitCode: initialLastExitCode,
                sourceLineOffset: sourceLineOffset,
                suppressesErrexit: suppressesErrexit,
                outputStream: outputStream,
                errorStream: errorStream
            )
        )
    }

    func updateConfiguration(_ update: (inout MSPConfiguration) -> Void) {
        var configuration = context.configuration()
        update(&configuration)
        context.setConfiguration(configuration)
    }

    func readDelimiter(from rawValue: String?) -> Character {
        guard let rawValue else {
            return "\n"
        }
        if rawValue.isEmpty {
            return "\0"
        }
        return rawValue.first ?? "\0"
    }

    func readRecordFrames(
        from data: Data,
        delimiter: Character
    ) -> [(record: String, consumedByteCount: Int)] {
        guard !data.isEmpty else {
            return []
        }
        let delimiterData = Data(String(delimiter).utf8)
        guard !delimiterData.isEmpty else {
            return []
        }

        var records: [(record: String, consumedByteCount: Int)] = []
        var offset = 0
        while offset < data.count {
            let remaining = data[offset..<data.count]
            if let delimiterRange = remaining.range(of: delimiterData) {
                let recordData = data[offset..<delimiterRange.lowerBound]
                records.append((
                    record: String(decoding: recordData, as: UTF8.self),
                    consumedByteCount: delimiterRange.upperBound - offset
                ))
                offset = delimiterRange.upperBound
            } else {
                let recordData = data[offset..<data.count]
                records.append((
                    record: String(decoding: recordData, as: UTF8.self),
                    consumedByteCount: data.count - offset
                ))
                break
            }
        }
        return records
    }

    func appendCompoundOutput(
        _ result: MSPCommandResult,
        stdout: inout String,
        stderr: inout String
    ) {
        stdout += result.stdout
        stderr += result.stderr
    }
}
