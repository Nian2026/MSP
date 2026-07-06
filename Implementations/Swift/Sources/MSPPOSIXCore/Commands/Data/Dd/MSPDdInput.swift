import Foundation
import MSPCore

enum MSPDdInput {
    case data(MSPDdDataInput)
    case file(MSPDdFileInput)
    case stream(MSPDdStandardInput)

    static func make(
        options: MSPDdOptions,
        context: MSPCommandContext,
        commandName: String
    ) throws -> MSPDdInput {
        if let inputPath = options.inputPath {
            let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: commandName)
            do {
                _ = try fileSystem.stat(inputPath, from: context.currentDirectory)
            } catch {
                throw MSPCommandFailure(result: .failure(
                    exitCode: 1,
                    stderr: "dd: failed to open '\(inputPath)': \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n"
                ))
            }
            return .file(
                MSPDdFileInput(
                    fileSystem: fileSystem,
                    path: inputPath,
                    currentDirectory: context.currentDirectory,
                    offset: UInt64(options.skipRecords * options.inputBlockSize)
                )
            )
        }

        if let standardInput = context.standardInputStream {
            return .stream(MSPDdStandardInput(
                stream: standardInput,
                skipRemaining: options.skipRecords * options.inputBlockSize
            ))
        }
        let data = try MSPPOSIXCommandSupport.standardInputData(from: context)
        return .data(MSPDdDataInput(data: data, offset: options.skipRecords * options.inputBlockSize))
    }

    mutating func readBlock(requestedBytes: Int, fullblock: Bool, chunkSize: Int) async throws -> Data {
        switch self {
        case .data(var input):
            let data = try await input.readBlock(requestedBytes: requestedBytes, fullblock: fullblock, chunkSize: chunkSize)
            self = .data(input)
            return data
        case .file(var input):
            let data = try await input.readBlock(requestedBytes: requestedBytes, fullblock: fullblock, chunkSize: chunkSize)
            self = .file(input)
            return data
        case .stream(var input):
            let data = try await input.readBlock(requestedBytes: requestedBytes, fullblock: fullblock, chunkSize: chunkSize)
            self = .stream(input)
            return data
        }
    }
}

struct MSPDdDataInput {
    var data: Data
    var offset: Int

    mutating func readBlock(requestedBytes: Int, fullblock: Bool, chunkSize: Int) async throws -> Data {
        guard offset < data.count else {
            return Data()
        }
        let end = min(data.count, offset + requestedBytes)
        let block = data.subdata(in: offset..<end)
        offset = end
        return block
    }
}

struct MSPDdFileInput {
    var fileSystem: any MSPWorkspaceFileSystem
    var path: String
    var currentDirectory: String
    var offset: UInt64

    mutating func readBlock(requestedBytes: Int, fullblock: Bool, chunkSize: Int) async throws -> Data {
        var output = Data()
        repeat {
            let request = fullblock ? min(chunkSize, requestedBytes - output.count) : requestedBytes
            let chunk = try fileSystem.readFileRange(path, from: currentDirectory, offset: offset, length: request)
            guard !chunk.isEmpty else {
                break
            }
            offset += UInt64(chunk.count)
            output.append(chunk)
        } while fullblock && output.count < requestedBytes
        return output
    }
}

struct MSPDdStandardInput {
    var stream: any MSPCommandInputStream
    var skipRemaining = 0
    var pending = Data()

    mutating func readBlock(requestedBytes: Int, fullblock: Bool, chunkSize: Int) async throws -> Data {
        while skipRemaining > 0 {
            guard let chunk = try await stream.read(maxBytes: min(chunkSize, skipRemaining)) else {
                skipRemaining = 0
                return Data()
            }
            let consumed = min(skipRemaining, chunk.count)
            skipRemaining -= consumed
            if consumed < chunk.count {
                pending.append(chunk.subdata(in: consumed..<chunk.count))
            }
        }
        while fullblock && pending.count < requestedBytes {
            guard let chunk = try await stream.read(maxBytes: min(chunkSize, requestedBytes - pending.count)) else {
                break
            }
            pending.append(chunk)
        }
        if !fullblock, pending.isEmpty, let chunk = try await stream.read(maxBytes: requestedBytes) {
            pending.append(chunk)
        }
        guard !pending.isEmpty else {
            return Data()
        }
        let count = min(requestedBytes, pending.count)
        let block = pending.subdata(in: 0..<count)
        pending.removeSubrange(0..<count)
        return block
    }
}
