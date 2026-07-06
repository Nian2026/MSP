import Foundation
import MSPCore

public struct MSPSumCommand: MSPCommand {
    public let name = "sum"
    public let summary: String? = "Print BSD or System V checksums and block counts."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") {
            return .success(stdout: mspSumUsage)
        }
        if invocation.arguments.contains("--version") {
            return .success(stdout: "sum (GNU coreutils) 9.1\n")
        }
        let parsed = try MSPPOSIXCommandSpec(
            name: name,
            allowedShortOptions: ["r", "s"],
            allowedLongOptions: ["sysv", "help", "version"]
        ).parse(invocation.arguments)
        let algorithm: MSPSumAlgorithm = parsed.options.contains { $0.matches(short: "s", long: "sysv") } ? .sysv : .bsd
        let operands = parsed.operands
        if operands.isEmpty {
            return .success(stdout: mspSumRender(data: context.standardInput, label: nil, algorithm: algorithm) + "\n")
        }

        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        var stdout = ""
        var stderr = ""
        var ok = true
        var standardInputConsumed = false
        for operand in operands {
            do {
                let result: MSPSumResult
                if operand == "-" {
                    let data = standardInputConsumed ? Data() : context.standardInput
                    standardInputConsumed = true
                    result = mspSum(data: data, algorithm: algorithm)
                } else {
                    result = try mspSum(
                        fileSystem: fileSystem,
                        path: operand,
                        context: context,
                        algorithm: algorithm
                    )
                }
                stdout += mspSumRender(result: result, label: operand, algorithm: algorithm) + "\n"
            } catch {
                stderr += "sum: \(operand): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n"
                ok = false
            }
        }
        return MSPCommandResult(stdout: stdout, stderr: stderr, exitCode: ok ? 0 : 1)
    }
}

private let mspSumUsage = """
Usage: sum [OPTION]... [FILE]...
Print checksum and block counts for each FILE.

"""

private enum MSPSumAlgorithm {
    case bsd
    case sysv
}

private struct MSPSumResult {
    var checksum: UInt32
    var length: UInt64
}

private struct MSPSumState {
    var algorithm: MSPSumAlgorithm
    var bsdChecksum: UInt32 = 0
    var sysvSum: UInt32 = 0
    var length: UInt64 = 0

    mutating func update(with data: Data) {
        length += UInt64(data.count)
        switch algorithm {
        case .bsd:
            for byte in data {
                bsdChecksum = (bsdChecksum >> 1) + ((bsdChecksum & 1) << 15)
                bsdChecksum = (bsdChecksum + UInt32(byte)) & 0xffff
            }
        case .sysv:
            for byte in data {
                sysvSum = sysvSum &+ UInt32(byte)
            }
        }
    }

    func finish() -> MSPSumResult {
        switch algorithm {
        case .bsd:
            return MSPSumResult(checksum: bsdChecksum, length: length)
        case .sysv:
            let r = (sysvSum & 0xffff) + (sysvSum >> 16)
            return MSPSumResult(checksum: (r & 0xffff) + (r >> 16), length: length)
        }
    }
}

private func mspSumRender(data: Data, label: String?, algorithm: MSPSumAlgorithm) -> String {
    mspSumRender(result: mspSum(data: data, algorithm: algorithm), label: label, algorithm: algorithm)
}

private func mspSumRender(result: MSPSumResult, label: String?, algorithm: MSPSumAlgorithm) -> String {
    switch algorithm {
    case .bsd:
        let blocks = (result.length + 1023) / 1024
        let prefix = String(format: "%05u %5llu", result.checksum, blocks)
        return label.map { "\(prefix) \($0)" } ?? prefix
    case .sysv:
        let blocks = (result.length + 511) / 512
        let prefix = "\(result.checksum) \(blocks)"
        return label.map { "\(prefix) \($0)" } ?? prefix
    }
}

private func mspSum(data: Data, algorithm: MSPSumAlgorithm) -> MSPSumResult {
    var state = MSPSumState(algorithm: algorithm)
    state.update(with: data)
    return state.finish()
}

private func mspSum(
    fileSystem: any MSPWorkspaceFileSystem,
    path: String,
    context: MSPCommandContext,
    algorithm: MSPSumAlgorithm
) throws -> MSPSumResult {
    var state = MSPSumState(algorithm: algorithm)
    var offset: UInt64 = 0
    let chunkSize = 32 * 1024
    while true {
        let chunk = try fileSystem.readFileRange(path, from: context.currentDirectory, offset: offset, length: chunkSize)
        guard !chunk.isEmpty else {
            return state.finish()
        }
        state.update(with: chunk)
        offset += UInt64(chunk.count)
    }
}
