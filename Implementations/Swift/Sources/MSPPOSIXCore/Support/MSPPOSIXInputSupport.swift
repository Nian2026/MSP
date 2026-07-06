import Foundation
import MSPCore

struct MSPPOSIXInput {
    var label: String?
    var data: Data
}

extension MSPPOSIXCommandSupport {
    static func inputData(
        operands: [String],
        context: MSPCommandContext,
        command: String,
        readStandardInputWhenEmpty: Bool = true,
        fileReadDiagnostic: ((String, String) -> String)? = nil
    ) async throws -> (inputs: [MSPPOSIXInput], diagnostics: [String], exitCode: Int32) {
        if operands.isEmpty, readStandardInputWhenEmpty {
            do {
                return ([MSPPOSIXInput(label: nil, data: try await collectedStandardInputData(from: context))], [], 0)
            } catch {
                return ([], ["\(command): stdin: \(diagnosticReason(from: error))"], 1)
            }
        }

        var fileSystem: (any MSPWorkspaceFileSystem)?
        var standardInputConsumed = false
        var inputs: [MSPPOSIXInput] = []
        var diagnostics: [String] = []
        var exitCode: Int32 = 0

        for operand in operands {
            if operand == "-" {
                let data: Data
                if standardInputConsumed {
                    data = Data()
                } else {
                    standardInputConsumed = true
                    do {
                        data = try await collectedStandardInputData(from: context)
                    } catch {
                        diagnostics.append("\(command): stdin: \(diagnosticReason(from: error))")
                        exitCode = 1
                        continue
                    }
                }
                inputs.append(MSPPOSIXInput(label: "-", data: data))
                continue
            }

            do {
                if fileSystem == nil {
                    fileSystem = try workspaceFileSystem(from: context, command: command)
                }
                let data = try fileSystem!.readFile(operand, from: context.currentDirectory)
                inputs.append(MSPPOSIXInput(label: operand, data: data))
            } catch {
                let displayPath = displayPath(operand)
                let reason = diagnosticReason(from: error)
                diagnostics.append(
                    fileReadDiagnostic?(displayPath, reason)
                        ?? "\(command): \(displayPath): \(reason)"
                )
                exitCode = 1
            }
        }

        return (inputs, diagnostics, exitCode)
    }

    static func collectedStandardInputData(from context: MSPCommandContext) async throws -> Data {
        if let stream = context.standardInputStream {
            var data = Data()
            while let chunk = try await stream.read(maxBytes: 32 * 1024) {
                data.append(chunk)
            }
            return data
        }
        return try standardInputData(from: context)
    }
}
