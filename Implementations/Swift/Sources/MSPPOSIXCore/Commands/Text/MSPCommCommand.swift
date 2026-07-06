import Foundation
import MSPCore

public struct MSPCommCommand: MSPCommand {
    public let name = "comm"
    public let summary: String? = "Compare two sorted files line by line."

    private let spec = MSPPOSIXCommandSpec(
        name: "comm",
        allowedShortOptions: ["1", "2", "3", "z"],
        allowedLongOptions: ["zero-terminated", "check-order", "nocheck-order", "total", "help", "version"],
        longOptionsRequiringValue: ["output-delimiter"]
    )

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let parsed = try spec.parse(invocation.arguments)
        if let standardOption = standardOptionResult(from: parsed.options) {
            return standardOption
        }
        try spec.requireOperandCount(parsed.operands, min: 2, max: 2)
        guard parsed.operands != ["-", "-"] else {
            return .failure(stderr: "comm: both files cannot be standard input\n")
        }
        if let duplicateDelimiterFailure = duplicateOutputDelimiterFailure(in: parsed.options) {
            return duplicateDelimiterFailure
        }
        let suppressFirst = parsed.options.contains { $0.matches(short: "1") }
        let suppressSecond = parsed.options.contains { $0.matches(short: "2") }
        let suppressCommon = parsed.options.contains { $0.matches(short: "3") }
        let zeroTerminated = parsed.options.contains { $0.matches(short: "z", long: "zero-terminated") }
        let orderMode = inputOrderMode(from: parsed.options)
        let checkOrder = orderMode == .enabled
        let noCheckOrder = orderMode == .disabled
        let outputDelimiter = outputDelimiterData(parsed.options.lastValue(long: "output-delimiter"))
        let includeTotal = parsed.options.contains { $0.matches(long: "total") }
        let delimiter: UInt8 = zeroTerminated ? 0 : 0x0a

        var standardInputConsumed = false
        let firstData = try inputData(
            operand: parsed.operands[0],
            context: context,
            standardInputConsumed: &standardInputConsumed
        )
        let secondData = try inputData(
            operand: parsed.operands[1],
            context: context,
            standardInputConsumed: &standardInputConsumed
        )

        var firstCursor = CommRecordCursor(data: firstData, delimiter: delimiter)
        var secondCursor = CommRecordCursor(data: secondData, delimiter: delimiter)
        var output = Data()
        var totals = [0, 0, 0]
        var seenUnpairable = false
        var issuedDisorderWarning = [false, false]
        var orderDiagnostics: [String] = []

        func orderFailureIfNeeded(_ cursor: CommRecordCursor, operandIndex: Int) -> MSPCommandResult? {
            guard checkOrder, cursor.recentlyUnsorted else {
                return nil
            }
            return .failure(
                exitCode: 1,
                stdoutData: output,
                stderr: "comm: file \(operandIndex) is not in sorted order\n"
            )
        }

        func recordDefaultOrderWarningIfNeeded(_ cursor: CommRecordCursor, operandIndex: Int) {
            guard !noCheckOrder, !checkOrder, seenUnpairable, cursor.recentlyUnsorted else {
                return
            }
            let warningIndex = operandIndex - 1
            guard !issuedDisorderWarning[warningIndex] else {
                return
            }
            orderDiagnostics.append("comm: file \(operandIndex) is not in sorted order")
            issuedDisorderWarning[warningIndex] = true
        }

        while firstCursor.current != nil || secondCursor.current != nil {
            if firstCursor.current == nil {
                seenUnpairable = true
                totals[1] += 1
                if !suppressSecond {
                    appendLine(
                        secondCursor.current ?? Data(),
                        column: 2,
                        suppressFirst: suppressFirst,
                        suppressSecond: suppressSecond,
                        outputDelimiter: outputDelimiter,
                        recordDelimiter: delimiter,
                        to: &output
                    )
                }
                secondCursor.advance()
                if let failure = orderFailureIfNeeded(secondCursor, operandIndex: 2) {
                    return failure
                }
                recordDefaultOrderWarningIfNeeded(secondCursor, operandIndex: 2)
                continue
            }
            if secondCursor.current == nil {
                seenUnpairable = true
                totals[0] += 1
                if !suppressFirst {
                    appendLine(
                        firstCursor.current ?? Data(),
                        column: 1,
                        suppressFirst: suppressFirst,
                        suppressSecond: suppressSecond,
                        outputDelimiter: outputDelimiter,
                        recordDelimiter: delimiter,
                        to: &output
                    )
                }
                firstCursor.advance()
                if let failure = orderFailureIfNeeded(firstCursor, operandIndex: 1) {
                    return failure
                }
                recordDefaultOrderWarningIfNeeded(firstCursor, operandIndex: 1)
                continue
            }
            let firstRow = firstCursor.current ?? Data()
            let secondRow = secondCursor.current ?? Data()
            let comparison = firstRow.lexicographicallyPrecedes(secondRow)
                ? ComparisonResult.orderedAscending
                : (secondRow.lexicographicallyPrecedes(firstRow) ? .orderedDescending : .orderedSame)
            if comparison == .orderedAscending {
                seenUnpairable = true
                totals[0] += 1
                if !suppressFirst {
                    appendLine(
                        firstRow,
                        column: 1,
                        suppressFirst: suppressFirst,
                        suppressSecond: suppressSecond,
                        outputDelimiter: outputDelimiter,
                        recordDelimiter: delimiter,
                        to: &output
                    )
                }
                firstCursor.advance()
                if let failure = orderFailureIfNeeded(firstCursor, operandIndex: 1) {
                    return failure
                }
                recordDefaultOrderWarningIfNeeded(firstCursor, operandIndex: 1)
            } else if comparison == .orderedDescending {
                seenUnpairable = true
                totals[1] += 1
                if !suppressSecond {
                    appendLine(
                        secondRow,
                        column: 2,
                        suppressFirst: suppressFirst,
                        suppressSecond: suppressSecond,
                        outputDelimiter: outputDelimiter,
                        recordDelimiter: delimiter,
                        to: &output
                    )
                }
                secondCursor.advance()
                if let failure = orderFailureIfNeeded(secondCursor, operandIndex: 2) {
                    return failure
                }
                recordDefaultOrderWarningIfNeeded(secondCursor, operandIndex: 2)
            } else {
                totals[2] += 1
                if !suppressCommon {
                    appendLine(
                        firstRow,
                        column: 3,
                        suppressFirst: suppressFirst,
                        suppressSecond: suppressSecond,
                        outputDelimiter: outputDelimiter,
                        recordDelimiter: delimiter,
                        to: &output
                    )
                }
                firstCursor.advance()
                if let failure = orderFailureIfNeeded(firstCursor, operandIndex: 1) {
                    return failure
                }
                recordDefaultOrderWarningIfNeeded(firstCursor, operandIndex: 1)
                secondCursor.advance()
                if let failure = orderFailureIfNeeded(secondCursor, operandIndex: 2) {
                    return failure
                }
                recordDefaultOrderWarningIfNeeded(secondCursor, operandIndex: 2)
            }
        }
        if !noCheckOrder, !checkOrder, seenUnpairable {
            recordEndOfFileOrderWarningIfNeeded(
                firstCursor,
                operandIndex: 1,
                issuedDisorderWarning: &issuedDisorderWarning,
                diagnostics: &orderDiagnostics
            )
            recordEndOfFileOrderWarningIfNeeded(
                secondCursor,
                operandIndex: 2,
                issuedDisorderWarning: &issuedDisorderWarning,
                diagnostics: &orderDiagnostics
            )
        }
        if includeTotal {
            appendTotalLine(totals, outputDelimiter: outputDelimiter, recordDelimiter: delimiter, to: &output)
        }
        if !orderDiagnostics.isEmpty {
            orderDiagnostics.append("comm: input is not in sorted order")
            return .failure(
                stdoutData: output,
                stderr: orderDiagnostics.joined(separator: "\n") + "\n"
            )
        }
        return .success(stdoutData: output)
    }

    private func standardOptionResult(from options: [MSPPOSIXOption]) -> MSPCommandResult? {
        if options.contains(where: { $0.matches(long: "help") }) {
            return .success(stdout: Self.helpText)
        }
        if options.contains(where: { $0.matches(long: "version") }) {
            return .success(stdout: Self.versionText)
        }
        return nil
    }

    private func duplicateOutputDelimiterFailure(in options: [MSPPOSIXOption]) -> MSPCommandResult? {
        var seen: String?
        for option in options where option.matches(long: "output-delimiter") {
            let value = option.value ?? ""
            if let seen, seen != value {
                return .failure(stderr: "comm: multiple output delimiters specified\n")
            }
            seen = value
        }
        return nil
    }

    private func outputDelimiterData(_ rawValue: String?) -> Data {
        guard let rawValue else {
            return Data([0x09])
        }
        return rawValue.isEmpty ? Data([0]) : Data(rawValue.utf8)
    }

    private func inputOrderMode(from options: [MSPPOSIXOption]) -> CommInputOrderMode {
        var mode = CommInputOrderMode.default
        for option in options {
            if option.matches(long: "check-order") {
                mode = .enabled
            } else if option.matches(long: "nocheck-order") {
                mode = .disabled
            }
        }
        return mode
    }

    private func inputData(
        operand: String,
        context: MSPCommandContext,
        standardInputConsumed: inout Bool
    ) throws -> Data {
        if operand == "-" {
            guard !standardInputConsumed else { return Data() }
            standardInputConsumed = true
            return context.standardInput
        }
        do {
            let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
            return try fileSystem.readFile(operand, from: context.currentDirectory)
        } catch let failure as MSPCommandFailure {
            throw failure
        } catch {
            throw MSPCommandFailure(result: .failure(
                exitCode: 1,
                stderr: "comm: \(MSPPOSIXCommandSupport.displayPath(operand)): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n"
            ))
        }
    }

    private func recordEndOfFileOrderWarningIfNeeded(
        _ cursor: CommRecordCursor,
        operandIndex: Int,
        issuedDisorderWarning: inout [Bool],
        diagnostics: inout [String]
    ) {
        guard cursor.lastPairUnsorted else {
            return
        }
        let warningIndex = operandIndex - 1
        guard !issuedDisorderWarning[warningIndex] else {
            return
        }
        diagnostics.append("comm: file \(operandIndex) is not in sorted order")
        issuedDisorderWarning[warningIndex] = true
    }

    private func appendLine(
        _ line: Data,
        column: Int,
        suppressFirst: Bool,
        suppressSecond: Bool,
        outputDelimiter: Data,
        recordDelimiter: UInt8,
        to output: inout Data
    ) {
        switch column {
        case 1:
            break
        case 2:
            if !suppressFirst { output.append(outputDelimiter) }
        default:
            if !suppressFirst { output.append(outputDelimiter) }
            if !suppressSecond { output.append(outputDelimiter) }
        }
        output.append(line)
        output.append(recordDelimiter)
    }

    private func appendTotalLine(
        _ totals: [Int],
        outputDelimiter: Data,
        recordDelimiter: UInt8,
        to output: inout Data
    ) {
        output.append(contentsOf: String(totals[0]).utf8)
        output.append(outputDelimiter)
        output.append(contentsOf: String(totals[1]).utf8)
        output.append(outputDelimiter)
        output.append(contentsOf: String(totals[2]).utf8)
        output.append(outputDelimiter)
        output.append(contentsOf: "total".utf8)
        output.append(recordDelimiter)
    }

    private static let helpText = """
    Usage: comm [OPTION]... FILE1 FILE2
    Compare sorted files FILE1 and FILE2 line by line.

    When FILE1 or FILE2 (not both) is -, read standard input.

      -1                      suppress column 1 (lines unique to FILE1)
      -2                      suppress column 2 (lines unique to FILE2)
      -3                      suppress column 3 (lines that appear in both files)
          --check-order       check that the input is correctly sorted
          --nocheck-order     do not check that the input is correctly sorted
          --output-delimiter=STR  separate columns with STR
          --total             output a summary
      -z, --zero-terminated   line delimiter is NUL, not newline
          --help        display this help and exit
          --version     output version information and exit

    GNU coreutils online help: <https://www.gnu.org/software/coreutils/>
    Full documentation <https://www.gnu.org/software/coreutils/comm>
    or available locally via: info '(coreutils) comm invocation'
    """

    private static let versionText = """
    comm (GNU coreutils) 9.1
    Copyright (C) 2022 Free Software Foundation, Inc.
    License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.
    This is free software: you are free to change and redistribute it.
    There is NO WARRANTY, to the extent permitted by law.

    Written by Richard Stallman and David MacKenzie.
    """
}

private enum CommInputOrderMode {
    case `default`
    case enabled
    case disabled
}

private struct CommRecordCursor {
    private let data: Data
    private let delimiter: UInt8
    private var offset: Data.Index
    private var previous: Data?
    private(set) var current: Data?
    private(set) var recentlyUnsorted = false
    private(set) var lastPairUnsorted = false

    init(data: Data, delimiter: UInt8) {
        self.data = data
        self.delimiter = delimiter
        self.offset = data.startIndex
        self.previous = nil
        self.current = nil
        self.current = readNextRecord()
    }

    mutating func advance() {
        previous = current
        current = readNextRecord()
        recentlyUnsorted = false
        if let previous, let current {
            let unsorted = current.lexicographicallyPrecedes(previous)
            recentlyUnsorted = unsorted
            lastPairUnsorted = unsorted
        }
    }

    private mutating func readNextRecord() -> Data? {
        guard offset < data.endIndex else {
            return nil
        }
        let start = offset
        while offset < data.endIndex {
            if data[offset] == delimiter {
                let record = data.subdata(in: start..<offset)
                offset = data.index(after: offset)
                return record
            }
            offset = data.index(after: offset)
        }
        return start < data.endIndex ? data.subdata(in: start..<data.endIndex) : nil
    }
}

private extension Array where Element == MSPPOSIXOption {
    func lastValue(long: String) -> String? {
        reversed().first { $0.matches(long: long) }?.value
    }
}
