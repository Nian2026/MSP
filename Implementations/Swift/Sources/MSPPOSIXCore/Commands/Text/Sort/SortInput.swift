import Foundation
import MSPCore

func sortInputOperands(
    commandLineOperands: [String],
    files0From: String?,
    context: MSPCommandContext
) throws -> [String] {
    guard let files0From else {
        return commandLineOperands
    }
    guard commandLineOperands.isEmpty else {
        let firstOperand = commandLineOperands[0]
        throw MSPCommandFailure(result: .failure(
            exitCode: 2,
            stderr: """
            sort: extra operand '\(firstOperand)'
            file operands cannot be combined with --files0-from
            Try 'sort --help' for more information.

            """
        ))
    }

    let listData: Data
    if files0From == "-" {
        do {
            listData = try MSPPOSIXCommandSupport.standardInputData(from: context)
        } catch {
            throw MSPCommandFailure(result: .failure(
                exitCode: 2,
                stderr: "sort: \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n"
            ))
        }
    } else {
        do {
            let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: "sort")
            listData = try fileSystem.readFile(files0From, from: context.currentDirectory)
        } catch {
            throw MSPCommandFailure(result: .failure(
                exitCode: 2,
                stderr: "sort: \(files0From): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n"
            ))
        }
    }

    let operands = sortFiles0Tokens(in: listData)
    guard !operands.isEmpty else {
        throw MSPCommandFailure(result: .failure(
            exitCode: 2,
            stderr: "sort: no input from '\(files0From)'\n"
        ))
    }
    for (index, operand) in operands.enumerated() {
        if operand == "-" {
            throw MSPCommandFailure(result: .failure(
                exitCode: 2,
                stderr: "sort: when reading file names from stdin, no file name of '-' allowed\n"
            ))
        }
        if operand.isEmpty {
            throw MSPCommandFailure(result: .failure(
                exitCode: 2,
                stderr: "sort: \(files0From):\(index + 1): invalid zero-length file name\n"
            ))
        }
    }
    return operands
}

private func sortFiles0Tokens(in data: Data) -> [String] {
    guard !data.isEmpty else {
        return []
    }
    var tokens: [String] = []
    var start = data.startIndex
    var index = start
    while index < data.endIndex {
        if data[index] == 0 {
            tokens.append(String(decoding: data[start..<index], as: UTF8.self))
            start = data.index(after: index)
        }
        index = data.index(after: index)
    }
    if start < data.endIndex {
        tokens.append(String(decoding: data[start..<data.endIndex], as: UTF8.self))
    }
    return tokens
}
