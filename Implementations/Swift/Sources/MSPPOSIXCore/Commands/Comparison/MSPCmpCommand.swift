import Foundation
import MSPCore

public struct MSPCmpCommand: MSPCommand {
    public let name = "cmp"
    public let summary: String? = "Compare two files byte by byte."

    private let spec = MSPPOSIXCommandSpec(
        name: "cmp",
        allowedShortOptions: ["l", "s", "n", "i"],
        allowedLongOptions: ["silent", "quiet", "verbose", "help", "version", "bytes", "ignore-initial"],
        shortOptionsRequiringValue: ["n", "i"],
        longOptionsRequiringValue: ["bytes", "ignore-initial"]
    )

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") {
            return .success(stdout: mspCmpUsage)
        }
        if invocation.arguments.contains("--version") {
            return .success(stdout: "cmp (GNU diffutils) 3.8\n")
        }
        let parsed = try spec.parse(invocation.arguments)
        try spec.requireOperandCount(parsed.operands, min: 1, max: 4)
        let options = try cmpOptions(from: parsed)
        let operandPair: [String]
        let operandSkipValues: [String]
        if parsed.operands.count == 1 {
            operandPair = [parsed.operands[0], "-"]
            operandSkipValues = []
        } else {
            operandPair = Array(parsed.operands.prefix(2))
            operandSkipValues = Array(parsed.operands.dropFirst(2))
        }
        let operandSkips = try cmpOperandSkips(from: operandSkipValues)
        let skips = (
            lhs: options.skipLhs ?? operandSkips.lhs,
            rhs: options.skipRhs ?? operandSkips.rhs
        )
        let operands = operandPair
        let silent = parsed.options.contains {
            $0.matches(short: "s", long: "silent") || $0.matches(long: "quiet")
        }
        let verbose = parsed.options.contains { $0.matches(short: "l", long: "verbose") }
        if silent, verbose {
            throw MSPCommandFailure.usage("cmp: options -l and -s are incompatible\n")
        }
        if operands[0] != "-", operands[1] != "-" {
            return try compareFileOperands(
                lhsPath: operands[0],
                rhsPath: operands[1],
                context: context,
                silent: silent,
                verbose: verbose,
                skipLhs: skips.lhs,
                skipRhs: skips.rhs,
                limit: options.limit
            )
        }
        let lhs: (displayPath: String, data: Data)
        let rhs: (displayPath: String, data: Data)
        do {
            lhs = try readOperand(
                operands[0],
                context: context,
                standardInputConsumed: false,
                skip: skips.lhs,
                limit: options.limit
            )
            rhs = try readOperand(
                operands[1],
                context: context,
                standardInputConsumed: operands[0] == "-",
                skip: skips.rhs,
                limit: options.limit
            )
        } catch let error as MSPCmpReadError {
            return MSPCommandResult(
                stderr: silent ? "" : "cmp: \(error.path): \(MSPPOSIXCommandSupport.diagnosticReason(from: error.underlying))\n",
                exitCode: 2
            )
        }

        if lhs.data == rhs.data {
            return .success()
        }
        if silent {
            return MSPCommandResult(exitCode: 1)
        }
        if verbose {
            return verboseComparison(lhsPath: lhs.displayPath, lhs: lhs.data, rhsPath: rhs.displayPath, rhs: rhs.data)
        }
        let difference = firstDifference(lhs.data, rhs.data)
        switch difference.kind {
        case .byteMismatch:
            return MSPCommandResult(
                stdout: "\(lhs.displayPath) \(rhs.displayPath) differ: byte \(difference.byteOffset), line \(difference.lineNumber)\n",
                exitCode: 1
            )
        case .lhsEOF:
            return MSPCommandResult(
                stderr: eofMessage(path: lhs.displayPath, difference: difference),
                exitCode: 1
            )
        case .rhsEOF:
            return MSPCommandResult(
                stderr: eofMessage(path: rhs.displayPath, difference: difference),
                exitCode: 1
            )
        }
    }

    private func compareFileOperands(
        lhsPath: String,
        rhsPath: String,
        context: MSPCommandContext,
        silent: Bool,
        verbose: Bool,
        skipLhs: Int,
        skipRhs: Int,
        limit: Int?
    ) throws -> MSPCommandResult {
        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        if verbose {
            do {
                let lhs = try readFileThroughRanges(
                    fileSystem: fileSystem,
                    path: lhsPath,
                    context: context,
                    skip: skipLhs,
                    limit: limit
                )
                let rhs = try readFileThroughRanges(
                    fileSystem: fileSystem,
                    path: rhsPath,
                    context: context,
                    skip: skipRhs,
                    limit: limit
                )
                return verboseComparison(lhsPath: lhsPath, lhs: lhs, rhsPath: rhsPath, rhs: rhs)
            } catch let error as MSPCmpReadError {
                return cmpReadFailure(path: error.path, underlying: error.underlying, silent: silent)
            }
        }
        var offset: UInt64 = 0
        var line = 1
        var lastEqualByte: UInt8?
        let chunkSize = 32 * 1024
        var remaining = limit

        while true {
            if remaining == 0 {
                return .success()
            }
            let requested = remaining.map { min(chunkSize, $0) } ?? chunkSize
            let lhsChunk: Data
            let rhsChunk: Data
            do {
                lhsChunk = try fileSystem.readFileRange(
                    lhsPath,
                    from: context.currentDirectory,
                    offset: UInt64(skipLhs) + offset,
                    length: requested
                )
            } catch {
                return cmpReadFailure(path: lhsPath, underlying: error, silent: silent)
            }
            do {
                rhsChunk = try fileSystem.readFileRange(
                    rhsPath,
                    from: context.currentDirectory,
                    offset: UInt64(skipRhs) + offset,
                    length: requested
                )
            } catch {
                return cmpReadFailure(path: rhsPath, underlying: error, silent: silent)
            }
            if let bytesRead = [lhsChunk.count, rhsChunk.count].max(), bytesRead > 0 {
                remaining = remaining.map { max(0, $0 - bytesRead) }
            }

            if lhsChunk.isEmpty, rhsChunk.isEmpty {
                return .success()
            }

            let comparedCount = min(lhsChunk.count, rhsChunk.count)
            for index in 0..<comparedCount {
                let lhsByte = lhsChunk[index]
                let rhsByte = rhsChunk[index]
                if lhsByte != rhsByte {
                    if silent {
                        return MSPCommandResult(exitCode: 1)
                    }
                    let difference = MSPCmpDifference(
                        kind: .byteMismatch,
                        byteOffset: Int(offset) + index + 1,
                        lineNumber: line,
                        eofAfterByte: nil,
                        eofStoppedAtLineBoundary: false
                    )
                    return MSPCommandResult(
                        stdout: "\(lhsPath) \(rhsPath) differ: byte \(difference.byteOffset), line \(difference.lineNumber)\n",
                        exitCode: 1
                    )
                }
                lastEqualByte = lhsByte
                if lhsByte == 0x0a {
                    line += 1
                }
            }

            if lhsChunk.count != rhsChunk.count {
                if silent {
                    return MSPCommandResult(exitCode: 1)
                }
                let lhsEnded = lhsChunk.count < rhsChunk.count
                let eofAfterByte = Int(offset) + (lhsEnded ? lhsChunk.count : rhsChunk.count)
                let eofStoppedAtLineBoundary = lastEqualByte == 0x0a
                let difference = MSPCmpDifference(
                    kind: lhsEnded ? .lhsEOF : .rhsEOF,
                    byteOffset: eofAfterByte + 1,
                    lineNumber: eofStoppedAtLineBoundary ? max(1, line - 1) : line,
                    eofAfterByte: eofAfterByte,
                    eofStoppedAtLineBoundary: eofStoppedAtLineBoundary
                )
                return MSPCommandResult(
                    stderr: eofMessage(path: lhsEnded ? lhsPath : rhsPath, difference: difference),
                    exitCode: 1
                )
            }

            offset += UInt64(comparedCount)
        }
    }

    private func cmpReadFailure(path: String, underlying: Error, silent: Bool) -> MSPCommandResult {
        MSPCommandResult(
            stderr: silent ? "" : "cmp: \(path): \(MSPPOSIXCommandSupport.diagnosticReason(from: underlying))\n",
            exitCode: 2
        )
    }

    private func readOperand(
        _ operand: String,
        context: MSPCommandContext,
        standardInputConsumed: Bool,
        skip: Int,
        limit: Int?
    ) throws -> (displayPath: String, data: Data) {
        if operand == "-" {
            let data = standardInputConsumed ? Data() : context.standardInput
            return ("-", cmpWindow(data, skip: skip, limit: limit))
        }
        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        do {
            return (
                operand,
                try readFileThroughRanges(
                    fileSystem: fileSystem,
                    path: operand,
                    context: context,
                    skip: skip,
                    limit: limit
                )
            )
        } catch {
            throw MSPCmpReadError(path: operand, underlying: error)
        }
    }

    private func readFileThroughRanges(
        fileSystem: any MSPWorkspaceFileSystem,
        path: String,
        context: MSPCommandContext,
        skip: Int = 0,
        limit: Int? = nil
    ) throws -> Data {
        var output = Data()
        var offset = UInt64(skip)
        let chunkSize = 32 * 1024
        var remaining = limit
        while true {
            if remaining == 0 {
                return output
            }
            let chunk: Data
            do {
                chunk = try fileSystem.readFileRange(
                    path,
                    from: context.currentDirectory,
                    offset: offset,
                    length: remaining.map { min(chunkSize, $0) } ?? chunkSize
                )
            } catch {
                throw MSPCmpReadError(path: path, underlying: error)
            }
            guard !chunk.isEmpty else {
                return output
            }
            output.append(chunk)
            offset += UInt64(chunk.count)
            remaining = remaining.map { max(0, $0 - chunk.count) }
        }
    }

    private func verboseComparison(lhsPath: String, lhs: Data, rhsPath: String, rhs: Data) -> MSPCommandResult {
        let comparedCount = min(lhs.count, rhs.count)
        let offsetWidth = String(comparedCount).count
        var rows: [String] = []
        for index in 0..<comparedCount where lhs[index] != rhs[index] {
            rows.append(String(
                format: "%*d %3o %3o",
                offsetWidth,
                index + 1,
                lhs[index],
                rhs[index]
            ))
        }
        if lhs.count == rhs.count {
            return rows.isEmpty ? .success() : MSPCommandResult(stdout: rows.joined(separator: "\n") + "\n", exitCode: 1)
        }
        let shorterPath = lhs.count < rhs.count ? lhsPath : rhsPath
        let eofAfterByte = comparedCount
        let stderr = eofAfterByte == 0
            ? "cmp: EOF on \(shorterPath) which is empty\n"
            : "cmp: EOF on \(shorterPath) after byte \(eofAfterByte)\n"
        return MSPCommandResult(
            stdout: rows.isEmpty ? "" : rows.joined(separator: "\n") + "\n",
            stderr: stderr,
            exitCode: 1
        )
    }

    private func eofMessage(path: String, difference: MSPCmpDifference) -> String {
        guard let eofAfterByte = difference.eofAfterByte, eofAfterByte > 0 else {
            return "cmp: EOF on \(path) which is empty\n"
        }
        let lineLabel = difference.eofStoppedAtLineBoundary ? "line" : "in line"
        return "cmp: EOF on \(path) after byte \(eofAfterByte), \(lineLabel) \(difference.lineNumber)\n"
    }
}

private let mspCmpUsage = """
Usage: cmp [OPTION]... FILE1 [FILE2]
Compare two files byte by byte.

"""

private struct MSPCmpReadError: Error {
    var path: String
    var underlying: Error
}

private struct MSPCmpOptions {
    var limit: Int?
    var skipLhs: Int?
    var skipRhs: Int?
}

private func cmpOptions(from parsed: MSPPOSIXParsedArguments) throws -> MSPCmpOptions {
    var options = MSPCmpOptions()
    for option in parsed.options {
        if option.matches(short: "n", long: "bytes") {
            options.limit = try cmpByteCount(option.value, optionName: MSPPOSIXOptionParser.optionDisplayName(option))
        } else if option.matches(short: "i", long: "ignore-initial") {
            let skips = try cmpSkipPair(option.value, optionName: MSPPOSIXOptionParser.optionDisplayName(option))
            options.skipLhs = skips.lhs
            options.skipRhs = skips.rhs
        }
    }
    return options
}

private func cmpOperandSkips(from values: [String]) throws -> (lhs: Int, rhs: Int) {
    guard values.count <= 2 else {
        throw MSPCommandFailure.usage("cmp: extra operand \(MSPPOSIXCommandSupport.gnuQuote(values[2]))\n")
    }
    let lhs = values.isEmpty ? 0 : try cmpByteCount(values[0], optionName: "SKIP1")
    let rhs = values.count < 2 ? 0 : try cmpByteCount(values[1], optionName: "SKIP2")
    return (lhs, rhs)
}

private func cmpSkipPair(_ value: String?, optionName: String) throws -> (lhs: Int, rhs: Int) {
    guard let value else {
        throw MSPCommandFailure.usage("cmp: option \(optionName) requires an argument\n")
    }
    let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    let lhs = try cmpByteCount(parts[0], optionName: optionName)
    let rhs = parts.count == 2 && !parts[1].isEmpty
        ? try cmpByteCount(parts[1], optionName: optionName)
        : lhs
    return (lhs, rhs)
}

private func cmpByteCount(_ value: String?, optionName: String) throws -> Int {
    guard var text = value, !text.isEmpty else {
        throw MSPCommandFailure.usage("cmp: invalid \(optionName) value \(MSPPOSIXCommandSupport.gnuQuote(value ?? ""))\n")
    }
    let suffixes: [(String, Int)] = [
        ("KiB", 1024), ("MiB", 1024 * 1024), ("GiB", 1024 * 1024 * 1024),
        ("K", 1024), ("M", 1024 * 1024), ("G", 1024 * 1024 * 1024),
        ("kB", 1000), ("MB", 1000 * 1000), ("GB", 1000 * 1000 * 1000)
    ]
    var multiplier = 1
    for (suffix, candidateMultiplier) in suffixes.sorted(by: { $0.0.count > $1.0.count }) where text.hasSuffix(suffix) {
        text.removeLast(suffix.count)
        multiplier = candidateMultiplier
        break
    }
    guard let base = Int(text), base >= 0 else {
        throw MSPCommandFailure.usage("cmp: invalid \(optionName) value \(MSPPOSIXCommandSupport.gnuQuote(value ?? ""))\n")
    }
    let multiplied = base.multipliedReportingOverflow(by: multiplier)
    guard !multiplied.overflow else {
        throw MSPCommandFailure.usage("cmp: \(optionName) value too large: \(MSPPOSIXCommandSupport.gnuQuote(value ?? ""))\n")
    }
    return multiplied.partialValue
}

private func cmpWindow(_ data: Data, skip: Int, limit: Int?) -> Data {
    guard skip < data.count else {
        return Data()
    }
    let start = skip
    let end = min(data.count, start + (limit ?? data.count))
    return data.subdata(in: start..<end)
}

private struct MSPCmpDifference {
    enum Kind {
        case byteMismatch
        case lhsEOF
        case rhsEOF
    }

    var kind: Kind
    var byteOffset: Int
    var lineNumber: Int
    var eofAfterByte: Int?
    var eofStoppedAtLineBoundary: Bool
}

private func firstDifference(_ lhs: Data, _ rhs: Data) -> MSPCmpDifference {
    let count = min(lhs.count, rhs.count)
    var line = 1
    for offset in 0..<count {
        if lhs[offset] != rhs[offset] {
            return MSPCmpDifference(
                kind: .byteMismatch,
                byteOffset: offset + 1,
                lineNumber: line,
                eofAfterByte: nil,
                eofStoppedAtLineBoundary: false
            )
        }
        if lhs[offset] == 0x0a {
            line += 1
        }
    }
    let lineAtEOF = line
    if lhs.count < rhs.count {
        let stoppedAtLineBoundary = lhs.last == 0x0a
        return MSPCmpDifference(
            kind: .lhsEOF,
            byteOffset: lhs.count + 1,
            lineNumber: stoppedAtLineBoundary ? max(1, lineAtEOF - 1) : lineAtEOF,
            eofAfterByte: lhs.count,
            eofStoppedAtLineBoundary: stoppedAtLineBoundary
        )
    }
    let stoppedAtLineBoundary = rhs.last == 0x0a
    return MSPCmpDifference(
        kind: .rhsEOF,
        byteOffset: rhs.count + 1,
        lineNumber: stoppedAtLineBoundary ? max(1, lineAtEOF - 1) : lineAtEOF,
        eofAfterByte: rhs.count,
        eofStoppedAtLineBoundary: stoppedAtLineBoundary
    )
}
