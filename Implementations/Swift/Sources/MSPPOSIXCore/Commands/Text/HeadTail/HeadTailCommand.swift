import Foundation
import MSPCore

struct MSPHeadTailCommand {
    enum Unit {
        case lines
        case bytes
    }

    enum Direction {
        case head
        case headAllButLast
        case tail
        case tailFromStart
    }

    enum HeaderMode {
        case automatic
        case never
        case always
    }

    var command: String

    func run(arguments: [String], context: MSPCommandContext) async throws -> MSPCommandResult {
        if let standardOption = standardOptionResult(arguments: arguments) {
            return standardOption
        }
        let selection = try parse(arguments)
        let showHeaders = selection.headerMode == .always
            || (selection.headerMode == .automatic && selection.operands.count > 1)

        var sections: [Data] = []
        var diagnostics: [String] = []
        var exitCode: Int32 = 0

        if selection.operands.isEmpty {
            do {
                var section = Data()
                if selection.headerMode == .always {
                    section.append(contentsOf: "==> standard input <==\n".utf8)
                }
                section.append(select(try MSPPOSIXCommandSupport.standardInputData(from: context), selection: selection))
                sections.append(section)
            } catch {
                diagnostics.append("\(command): stdin: \(MSPPOSIXCommandSupport.diagnosticReason(from: error))")
                exitCode = 1
            }
        } else {
            var fileSystem: (any MSPWorkspaceFileSystem)?
            var standardInputConsumed = false

            for operand in selection.operands {
                do {
                    let selectedData: Data
                    if operand == "-" {
                        if standardInputConsumed {
                            selectedData = Data()
                        } else {
                            standardInputConsumed = true
                            selectedData = select(
                                try MSPPOSIXCommandSupport.standardInputData(from: context),
                                selection: selection
                            )
                        }
                    } else {
                        if fileSystem == nil {
                            fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: command)
                        }
                        selectedData = try await selectFile(
                            operand,
                            fileSystem: fileSystem!,
                            currentDirectory: context.currentDirectory,
                            selection: selection
                        )
                    }

                    var section = Data()
                    if showHeaders {
                        section.append(contentsOf: "==> \(operand == "-" ? "standard input" : operand) <==\n".utf8)
                    }
                    section.append(selectedData)
                    sections.append(section)
                } catch {
                    let displayPath = MSPPOSIXCommandSupport.displayPath(operand)
                    let reason = MSPPOSIXCommandSupport.diagnosticReason(from: error)
                    diagnostics.append("\(command): cannot open '\(displayPath)' for reading: \(reason)")
                    exitCode = 1
                }
            }
        }

        let stdoutData = sections.enumerated().reduce(into: Data()) { output, item in
            let (offset, section) = item
            if showHeaders, offset > 0 {
                output.append(0x0A)
            }
            output.append(section)
        }
        let stderr = diagnostics.isEmpty
            ? ""
            : diagnostics.joined(separator: "\n") + "\n"
        return MSPCommandResult(stdoutData: stdoutData, stderr: stderr, exitCode: exitCode)
    }

    func runStreaming(arguments: [String], context: MSPCommandContext) async throws -> MSPCommandResult {
        if let standardOption = standardOptionResult(arguments: arguments) {
            return standardOption
        }
        let selection = try parse(arguments)
        guard selection.operands.isEmpty,
              command == "head",
              (selection.direction == .head || selection.direction == .headAllButLast),
              let standardInput = context.standardInputStream,
              let standardOutput = context.standardOutputStream
        else {
            if command == "tail",
               selection.operands.isEmpty,
               let standardInput = context.standardInputStream,
               let standardOutput = context.standardOutputStream {
                if selection.headerMode == .always {
                    try await standardOutput.write(Data("==> standard input <==\n".utf8))
                }
                do {
                    try await streamTail(
                        standardInput: standardInput,
                        standardOutput: standardOutput,
                        selection: selection
                    )
                } catch MSPCommandStreamError.brokenPipe {
                    return .success()
                }
                return .success()
            }
            return try await run(arguments: arguments, context: context)
        }

        if selection.headerMode == .always {
            try await standardOutput.write(Data("==> standard input <==\n".utf8))
        }
        do {
            try await streamHead(standardInput: standardInput, standardOutput: standardOutput, selection: selection)
        } catch MSPCommandStreamError.brokenPipe {
            return .success()
        }
        return .success()
    }
}
