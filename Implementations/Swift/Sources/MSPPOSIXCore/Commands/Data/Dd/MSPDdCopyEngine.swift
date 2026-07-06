import Foundation
import MSPCore

struct MSPDdCopyEngine {
    private let chunkSize = 32 * 1024

    func copy(
        options: MSPDdOptions,
        input: MSPDdInput,
        output: MSPDdOutput
    ) async throws -> MSPCommandResult {
        var input = input
        var output = output
        var stats = MSPDdStats()
        var outputBlock = Data()
        var savedSwabByte: UInt8?
        let maxRecords = options.count
        var recordsRead = 0

        func emitConverted(_ data: Data) async throws {
            guard !data.isEmpty else {
                return
            }
            outputBlock.append(data)
            while outputBlock.count >= options.outputBlockSize {
                let block = outputBlock.subdata(in: 0..<options.outputBlockSize)
                try await output.write(block)
                stats.outputFull += 1
                stats.bytesWritten += block.count
                outputBlock.removeSubrange(0..<options.outputBlockSize)
            }
        }

        while maxRecords.map({ recordsRead < $0 }) ?? true {
            var block = try await input.readBlock(
                requestedBytes: options.inputBlockSize,
                fullblock: options.fullblock,
                chunkSize: chunkSize
            )
            guard !block.isEmpty else {
                break
            }
            recordsRead += 1
            if block.count == options.inputBlockSize {
                stats.inputFull += 1
            } else {
                stats.inputPartial += 1
                if options.sync {
                    block.append(Data(repeating: 0, count: options.inputBlockSize - block.count))
                }
            }
            if options.swab {
                block = swabbed(block, savedByte: &savedSwabByte)
            }
            try await emitConverted(block)
        }

        if let savedSwabByte {
            try await emitConverted(Data([savedSwabByte]))
        }
        if !outputBlock.isEmpty {
            try await output.write(outputBlock)
            stats.outputPartial += 1
            stats.bytesWritten += outputBlock.count
        }
        try await output.finish()

        return MSPCommandResult(
            stdoutData: await output.stdoutData(),
            stderr: statusText(options.status, stats: stats),
            exitCode: 0
        )
    }

    private func swabbed(_ data: Data, savedByte: inout UInt8?) -> Data {
        var bytes = Array(data)
        if let saved = savedByte {
            bytes.insert(saved, at: 0)
            savedByte = nil
        }
        var output = Data()
        var index = 0
        while index + 1 < bytes.count {
            output.append(bytes[index + 1])
            output.append(bytes[index])
            index += 2
        }
        if index < bytes.count {
            savedByte = bytes[index]
        }
        return output
    }

    private func statusText(_ status: MSPDdStatus, stats: MSPDdStats) -> String {
        switch status {
        case .none:
            return ""
        case .noxfer:
            return "\(stats.inputFull)+\(stats.inputPartial) records in\n\(stats.outputFull)+\(stats.outputPartial) records out\n"
        case .default:
            return "\(stats.inputFull)+\(stats.inputPartial) records in\n"
                + "\(stats.outputFull)+\(stats.outputPartial) records out\n"
                + "\(stats.bytesWritten) bytes copied, 0 s, 0 B/s\n"
        }
    }
}

private struct MSPDdStats {
    var inputFull = 0
    var inputPartial = 0
    var outputFull = 0
    var outputPartial = 0
    var bytesWritten = 0
}
