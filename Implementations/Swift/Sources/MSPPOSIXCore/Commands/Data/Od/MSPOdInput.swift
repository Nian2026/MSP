import Foundation
import MSPCore

struct MSPOdVisibleInput {
    var data: Data
    var diagnostics: String
    var exitCode: Int32
}

enum MSPOdInput {
    static func load(
        operands: [String],
        context: MSPCommandContext,
        command: String,
        skipBytes: Int,
        byteLimit: Int?
    ) async throws -> MSPOdVisibleInput {
        if operands.count == 1,
           operands[0] != "-",
           (byteLimit != nil || skipBytes > 0) {
            return try readVisibleFileRange(
                operand: operands[0],
                context: context,
                command: command,
                skipBytes: skipBytes,
                byteLimit: byteLimit
            )
        }

        let input = try await MSPPOSIXCommandSupport.inputData(
            operands: operands,
            context: context,
            command: command
        )
        var data = input.inputs.reduce(into: Data()) { data, input in data.append(input.data) }
        if skipBytes > data.count {
            return MSPOdVisibleInput(
                data: Data(),
                diagnostics: "od: cannot skip past end of combined input\n",
                exitCode: 1
            )
        }
        if skipBytes > 0 {
            data = Data(data.dropFirst(skipBytes))
        }
        if let byteLimit, data.count > byteLimit {
            data = Data(data.prefix(byteLimit))
        }
        return MSPOdVisibleInput(
            data: data,
            diagnostics: input.diagnostics.isEmpty ? "" : input.diagnostics.joined(separator: "\n") + "\n",
            exitCode: input.exitCode
        )
    }

    private static func readVisibleFileRange(
        operand: String,
        context: MSPCommandContext,
        command: String,
        skipBytes: Int,
        byteLimit: Int?
    ) throws -> MSPOdVisibleInput {
        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: command)
        do {
            let info = try fileSystem.stat(operand, from: context.currentDirectory)
            let size = max(0, info.size ?? 0)
            if Int64(skipBytes) > size {
                return MSPOdVisibleInput(
                    data: Data(),
                    diagnostics: "od: cannot skip past end of combined input\n",
                    exitCode: 1
                )
            }
            let remaining = max(0, size - Int64(skipBytes))
            let requestedLength = byteLimit.map { min(Int64($0), remaining) } ?? remaining
            let safeLength = Int(min(Int64(Int.max), requestedLength))
            let data = try fileSystem.readFileRange(
                operand,
                from: context.currentDirectory,
                offset: UInt64(skipBytes),
                length: safeLength
            )
            return MSPOdVisibleInput(data: data, diagnostics: "", exitCode: 0)
        } catch {
            return MSPOdVisibleInput(
                data: Data(),
                diagnostics: "od: \(operand): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n",
                exitCode: 1
            )
        }
    }
}
