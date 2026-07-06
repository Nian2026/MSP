import Foundation
import MSPCore

public struct MSPDiffCommand: MSPCommand {
    public let name = "diff"
    public let summary: String? = "Compare files line by line."

    private let spec = MSPPOSIXCommandSpec(
        name: "diff",
        allowedShortOptions: ["u", "q", "s"],
        allowedLongOptions: ["unified", "brief", "report-identical-files"],
        shortOptionsRequiringValue: ["U"]
    )

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") {
            return .success(stdout: mspDiffHelp())
        }
        if invocation.arguments.contains("--version") || invocation.arguments.contains("-v") {
            return .success(stdout: "diff (GNU diffutils) 3.8\n")
        }
        let parsed = try spec.parse(invocation.arguments)
        try spec.requireOperandCount(parsed.operands, min: 2, max: 2)
        let unified = parsed.options.contains {
            $0.matches(short: "u", long: "unified") || $0.matches(short: "U")
        }
        let quiet = parsed.options.contains { $0.matches(short: "q", long: "brief") }
        let reportIdentical = parsed.options.contains { $0.matches(short: "s", long: "report-identical-files") }

        if quiet, parsed.operands[0] != "-", parsed.operands[1] != "-" {
            return try compareFileOperandsBrief(
                lhsPath: parsed.operands[0],
                rhsPath: parsed.operands[1],
                context: context,
                reportIdentical: reportIdentical
            )
        }

        var standardInputConsumed = false
        let lhs: MSPDiffOperand
        let rhs: MSPDiffOperand
        do {
            lhs = try materializedOperand(parsed.operands[0], context: context, standardInputConsumed: &standardInputConsumed)
            rhs = try materializedOperand(parsed.operands[1], context: context, standardInputConsumed: &standardInputConsumed)
        } catch let error as MSPDiffReadError {
            return MSPCommandResult(
                stderr: "diff: \(error.path): \(MSPPOSIXCommandSupport.diagnosticReason(from: error.underlying))\n",
                exitCode: 2
            )
        }
        guard lhs.data != rhs.data else {
            return .success(stdout: reportIdentical ? "Files \(lhs.displayPath) and \(rhs.displayPath) are identical\n" : "")
        }
        if quiet {
            return MSPCommandResult(stdout: "Files \(lhs.displayPath) and \(rhs.displayPath) differ\n", exitCode: 1)
        }
        if lhs.data.mspDiffLooksBinary || rhs.data.mspDiffLooksBinary {
            return MSPCommandResult(stdout: "Binary files \(lhs.displayPath) and \(rhs.displayPath) differ\n", exitCode: 1)
        }
        guard let lhsText = String(data: lhs.data, encoding: .utf8),
              let rhsText = String(data: rhs.data, encoding: .utf8) else {
            return MSPCommandResult(stdout: "Binary files \(lhs.displayPath) and \(rhs.displayPath) differ\n", exitCode: 1)
        }
        let output = unified
            ? unifiedDiff(lhs: lhs, lhsText: lhsText, rhs: rhs, rhsText: rhsText)
            : simpleDiff(lhsPath: lhs.displayPath, lhsText: lhsText, rhsPath: rhs.displayPath, rhsText: rhsText)
        return MSPCommandResult(stdout: output, exitCode: 1)
    }

    private func compareFileOperandsBrief(
        lhsPath: String,
        rhsPath: String,
        context: MSPCommandContext,
        reportIdentical: Bool
    ) throws -> MSPCommandResult {
        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        let chunkSize = 32 * 1024
        var offset: UInt64 = 0

        while true {
            let lhsChunk: Data
            let rhsChunk: Data
            do {
                lhsChunk = try fileSystem.readFileRange(
                    lhsPath,
                    from: context.currentDirectory,
                    offset: offset,
                    length: chunkSize
                )
            } catch {
                return MSPCommandResult(
                    stderr: "diff: \(lhsPath): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n",
                    exitCode: 2
                )
            }
            do {
                rhsChunk = try fileSystem.readFileRange(
                    rhsPath,
                    from: context.currentDirectory,
                    offset: offset,
                    length: chunkSize
                )
            } catch {
                return MSPCommandResult(
                    stderr: "diff: \(rhsPath): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n",
                    exitCode: 2
                )
            }

            if lhsChunk.isEmpty, rhsChunk.isEmpty {
                return .success(stdout: reportIdentical ? "Files \(lhsPath) and \(rhsPath) are identical\n" : "")
            }
            if lhsChunk != rhsChunk {
                return MSPCommandResult(stdout: "Files \(lhsPath) and \(rhsPath) differ\n", exitCode: 1)
            }
            offset += UInt64(lhsChunk.count)
        }
    }

    private func materializedOperand(
        _ operand: String,
        context: MSPCommandContext,
        standardInputConsumed: inout Bool
    ) throws -> MSPDiffOperand {
        if operand == "-" {
            defer { standardInputConsumed = true }
            return MSPDiffOperand(displayPath: "-", data: standardInputConsumed ? Data() : context.standardInput)
        }
        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        do {
            let data = try readFileChunked(
                operand,
                fileSystem: fileSystem,
                currentDirectory: context.currentDirectory
            )
            let info = try? fileSystem.stat(operand, from: context.currentDirectory)
            return MSPDiffOperand(displayPath: operand, data: data, modificationDate: info?.modificationDate)
        } catch {
            throw MSPDiffReadError(path: operand, underlying: error)
        }
    }

    private func readFileChunked(
        _ operand: String,
        fileSystem: any MSPWorkspaceFileSystem,
        currentDirectory: String
    ) throws -> Data {
        let chunkSize = 64 * 1024
        var offset: UInt64 = 0
        var data = Data()
        while true {
            let chunk = try fileSystem.readFileRange(
                operand,
                from: currentDirectory,
                offset: offset,
                length: chunkSize
            )
            guard !chunk.isEmpty else {
                return data
            }
            data.append(chunk)
            offset += UInt64(chunk.count)
        }
    }
}

private func mspDiffHelp() -> String {
    """
    Usage: diff [OPTION]... FILES
    Compare FILES line by line.

      -q, --brief                 report only when files differ
      -s, --report-identical-files
                                  report when two files are the same
      -u, -U NUM, --unified[=NUM] output NUM lines of unified context
          --help                  display this help and exit
      -v, --version               output version information and exit

    """
}

private extension Data {
    var mspDiffLooksBinary: Bool {
        contains(0)
    }
}

private struct MSPDiffOperand {
    var displayPath: String
    var data: Data
    var modificationDate: Date?
}

private struct MSPDiffReadError: Error {
    var path: String
    var underlying: Error
}

private func unifiedDiff(lhs: MSPDiffOperand, lhsText: String, rhs: MSPDiffOperand, rhsText: String) -> String {
    let lhsLines = diffLines(lhsText)
    let rhsLines = diffLines(rhsText)
    let changes = diffOperations(lhsLines, rhsLines)
    var lines = [
        unifiedHeader(prefix: "---", operand: lhs),
        unifiedHeader(prefix: "+++", operand: rhs),
        "@@ -\(unifiedDiffRange(start: 1, count: lhsLines.count)) +\(unifiedDiffRange(start: 1, count: rhsLines.count)) @@"
    ]
    for change in changes {
        switch change {
        case .equal(let line):
            lines.append(" \(line)")
        case .delete(let line):
            lines.append("-\(line)")
        case .insert(let line):
            lines.append("+\(line)")
        }
    }
    return lines.joined(separator: "\n") + "\n"
}

private func unifiedDiffRange(start: Int, count: Int) -> String {
    if count == 0 {
        return "\(max(start - 1, 0)),0"
    }
    if count == 1 {
        return "\(start)"
    }
    return "\(start),\(count)"
}

private func unifiedHeader(prefix: String, operand: MSPDiffOperand) -> String {
    guard let modificationDate = operand.modificationDate else {
        return "\(prefix) \(operand.displayPath)"
    }
    return "\(prefix) \(operand.displayPath)\t\(diffTimestamp(modificationDate))"
}

private func diffTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let nanosecond = Calendar(identifier: .gregorian)
        .dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date)
        .nanosecond ?? 0
    return "\(formatter.string(from: date)).\(String(format: "%09d", nanosecond)) +0000"
}

private func simpleDiff(lhsPath: String, lhsText: String, rhsPath: String, rhsText: String) -> String {
    let lhsLines = diffLines(lhsText)
    let rhsLines = diffLines(rhsText)
    let changes = diffOperations(lhsLines, rhsLines)
    var lhsLine = 1
    var rhsLine = 1
    var lines: [String] = []
    var index = 0
    while index < changes.count {
        let change = changes[index]
        switch change {
        case .equal:
            lhsLine += 1
            rhsLine += 1
            index += 1
        case .delete(let line):
            let lhsStart = lhsLine
            let rhsStart = rhsLine
            var deleted = [line]
            var inserted: [String] = []
            lhsLine += 1
            index += 1
            collectChangeGroup: while index < changes.count {
                switch changes[index] {
                case .delete(let deletedLine):
                    deleted.append(deletedLine)
                    lhsLine += 1
                    index += 1
                case .insert(let insertedLine):
                    inserted.append(insertedLine)
                    rhsLine += 1
                    index += 1
                case .equal:
                    break collectChangeGroup
                }
            }
            if inserted.isEmpty {
                lines.append("\(diffRange(lhsStart, lhsLine - 1))d\(max(rhsStart - 1, 0))")
                lines.append(contentsOf: deleted.map { "< \($0)" })
            } else {
                lines.append("\(diffRange(lhsStart, lhsLine - 1))c\(diffRange(rhsStart, rhsLine - 1))")
                lines.append(contentsOf: deleted.map { "< \($0)" })
                lines.append("---")
                lines.append(contentsOf: inserted.map { "> \($0)" })
            }
        case .insert(let line):
            let lhsStart = lhsLine
            let rhsStart = rhsLine
            var inserted = [line]
            rhsLine += 1
            index += 1
            while index < changes.count {
                if case .insert(let insertedLine) = changes[index] {
                    inserted.append(insertedLine)
                    rhsLine += 1
                    index += 1
                } else {
                    break
                }
            }
            lines.append("\(max(lhsStart - 1, 0))a\(diffRange(rhsStart, rhsLine - 1))")
            lines.append(contentsOf: inserted.map { "> \($0)" })
        }
    }
    if lines.isEmpty {
        lines.append("Files \(lhsPath) and \(rhsPath) differ")
    }
    return lines.joined(separator: "\n") + "\n"
}

private func diffRange(_ start: Int, _ end: Int) -> String {
    start == end ? "\(start)" : "\(start),\(end)"
}

private enum DiffOperation {
    case equal(String)
    case delete(String)
    case insert(String)
}

private func diffLines(_ text: String) -> [String] {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if text.hasSuffix("\n"), lines.last == "" {
        lines.removeLast()
    }
    return lines
}

private func diffOperations(_ lhs: [String], _ rhs: [String]) -> [DiffOperation] {
    var table = Array(
        repeating: Array(repeating: 0, count: rhs.count + 1),
        count: lhs.count + 1
    )
    if !lhs.isEmpty && !rhs.isEmpty {
        for i in stride(from: lhs.count - 1, through: 0, by: -1) {
            for j in stride(from: rhs.count - 1, through: 0, by: -1) {
                if lhs[i] == rhs[j] {
                    table[i][j] = table[i + 1][j + 1] + 1
                } else {
                    table[i][j] = max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
    }
    var operations: [DiffOperation] = []
    var i = 0
    var j = 0
    while i < lhs.count || j < rhs.count {
        if i < lhs.count, j < rhs.count, lhs[i] == rhs[j] {
            operations.append(.equal(lhs[i]))
            i += 1
            j += 1
        } else if i < lhs.count, (j == rhs.count || table[i + 1][j] >= table[i][j + 1]) {
            operations.append(.delete(lhs[i]))
            i += 1
        } else if j < rhs.count {
            operations.append(.insert(rhs[j]))
            j += 1
        }
    }
    return operations
}
