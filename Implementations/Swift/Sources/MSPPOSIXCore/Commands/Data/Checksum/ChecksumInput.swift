import Foundation
import MSPCore

func mspPOSIXChecksumRows(
    operands: [String],
    context: MSPCommandContext,
    command: String,
    stdinRender: (MSPPOSIXInput) -> Data,
    fileRender: (any MSPWorkspaceFileSystem, String) throws -> Data
) async throws -> (rows: [Data], diagnostics: [String], exitCode: Int32) {
    if operands.isEmpty {
        do {
            let input = MSPPOSIXInput(label: nil, data: try await MSPPOSIXCommandSupport.collectedStandardInputData(from: context))
            return ([stdinRender(input)], [], 0)
        } catch {
            return ([], ["\(command): stdin: \(MSPPOSIXCommandSupport.diagnosticReason(from: error))"], 1)
        }
    }

    var fileSystem: (any MSPWorkspaceFileSystem)?
    var standardInputConsumed = false
    var rows: [Data] = []
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
                    data = try await MSPPOSIXCommandSupport.collectedStandardInputData(from: context)
                } catch {
                    diagnostics.append("\(command): stdin: \(MSPPOSIXCommandSupport.diagnosticReason(from: error))")
                    exitCode = 1
                    continue
                }
            }
            rows.append(stdinRender(MSPPOSIXInput(label: "-", data: data)))
            continue
        }

        do {
            if fileSystem == nil {
                fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: command)
            }
            rows.append(try fileRender(fileSystem!, operand))
        } catch {
            let displayPath = MSPPOSIXCommandSupport.displayPath(operand)
            let reason = MSPPOSIXCommandSupport.diagnosticReason(from: error)
            diagnostics.append("\(command): \(displayPath): \(reason)")
            exitCode = 1
        }
    }

    return (rows, diagnostics, exitCode)
}

func mspPOSIXCksumFile(
    fileSystem: any MSPWorkspaceFileSystem,
    path: String,
    currentDirectory: String
) throws -> MSPPOSIXCRC32Result {
    var accumulator = MSPPOSIXCRC32Accumulator()
    try mspPOSIXReadFileChunks(fileSystem: fileSystem, path: path, currentDirectory: currentDirectory) { chunk in
        accumulator.update(chunk)
    }
    return accumulator.finalize()
}

func mspPOSIXReadFileChunks(
    fileSystem: any MSPWorkspaceFileSystem,
    path: String,
    currentDirectory: String,
    chunkSize: Int = 32 * 1024,
    consume: (Data) throws -> Void
) throws {
    let info = try fileSystem.stat(path, from: currentDirectory)
    guard let size = info.size else {
        try consume(fileSystem.readFile(path, from: currentDirectory))
        return
    }
    var offset: UInt64 = 0
    while offset < UInt64(max(0, size)) {
        let chunk = try fileSystem.readFileRange(path, from: currentDirectory, offset: offset, length: chunkSize)
        guard !chunk.isEmpty else {
            break
        }
        try consume(chunk)
        offset += UInt64(chunk.count)
    }
}
