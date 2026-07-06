import Foundation
import MSPCore

public struct MSPCutCommand: MSPStreamingCommand {
    public let name = "cut"
    public let summary: String? = "Remove selected byte, character, or field ranges."

    private let spec = MSPPOSIXCommandSpec(
        name: "cut",
        allowedShortOptions: ["n", "s", "z"],
        allowedLongOptions: ["only-delimited", "zero-terminated", "complement", "help", "version"],
        shortOptionsRequiringValue: ["b", "c", "d", "f"],
        longOptionsRequiringValue: ["bytes", "characters", "delimiter", "fields", "output-delimiter"]
    )

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let configuration = try parse(invocation.arguments)
        if let standardOption = configuration.standardOptionResult {
            return standardOption
        }
        let input = try await MSPPOSIXCommandSupport.inputData(
            operands: configuration.operands,
            context: context,
            command: name
        )
        let recordDelimiter: UInt8 = configuration.zeroTerminated ? 0 : 0x0a
        let outputSeparator = Data([recordDelimiter])
        let records = input.inputs.flatMap { mspPOSIXTextRecords(in: $0.data, delimiter: recordDelimiter) }
        let selected = try records.compactMap {
            try selectedCutRecord($0, configuration: configuration)
        }
        return MSPCommandResult(
            stdoutData: joinedRecords(selected, separator: outputSeparator),
            stderr: input.diagnostics.isEmpty ? "" : input.diagnostics.joined(separator: "\n") + "\n",
            exitCode: input.exitCode
        )
    }

    public func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let configuration = try parse(invocation.arguments)
        if let standardOption = configuration.standardOptionResult {
            return standardOption
        }
        guard configuration.operands.isEmpty || configuration.operands == ["-"],
              let standardInput = context.standardInputStream,
              let standardOutput = context.standardOutputStream
        else {
            return try await run(invocation: invocation, context: context)
        }

        do {
            try await streamCutOutput(
                standardInput: standardInput,
                standardOutput: standardOutput,
                configuration: configuration
            )
        } catch MSPCommandStreamError.brokenPipe {
            return .success()
        }
        return .success()
    }

    private func parse(_ arguments: [String]) throws -> MSPCutConfiguration {
        let parsed = try spec.parse(arguments)
        var delimiter: UInt8 = 0x09
        var selection: MSPCutSelection?
        var outputDelimiter: Data?
        var suppressUndelimited = false
        var complement = false
        var zeroTerminated = false
        var delimiterSpecified = false
        var standardOptionResult: MSPCommandResult?
        for option in parsed.options {
            switch option.name {
            case .short("b"), .long("bytes"):
                selection = try replace(selection, with: .bytes(try cutRangeSpec(
                    option.value ?? "",
                    command: name,
                    unitName: "byte position"
                )))
            case .short("c"), .long("characters"):
                selection = try replace(selection, with: .characters(try cutRangeSpec(
                    option.value ?? "",
                    command: name,
                    unitName: "character position"
                )))
            case .short("d"), .long("delimiter"):
                delimiterSpecified = true
                let rawBytes = Array((option.value ?? "").utf8)
                if rawBytes.isEmpty {
                    delimiter = 0
                    continue
                }
                guard rawBytes.count == 1, let byte = rawBytes.first else {
                    throw MSPCommandFailure(result: .failure(
                        exitCode: 1,
                        stderr: "cut: the delimiter must be a single character\nTry 'cut --help' for more information.\n"
                    ))
                }
                delimiter = byte
            case .short("f"), .long("fields"):
                selection = try replace(selection, with: .fields(try cutRangeSpec(
                    option.value ?? "",
                    command: name,
                    unitName: "field"
                )))
            case .long("output-delimiter"):
                let rawValue = option.value ?? ""
                outputDelimiter = rawValue.isEmpty ? Data([0]) : Data(rawValue.utf8)
            case .short("n"):
                continue
            case .short("s"), .long("only-delimited"):
                suppressUndelimited = true
            case .short("z"), .long("zero-terminated"):
                zeroTerminated = true
            case .long("complement"):
                complement = true
            case .long("help"):
                standardOptionResult = .success(stdout: Self.helpText)
            case .long("version"):
                standardOptionResult = .success(stdout: Self.versionText)
            default:
                continue
            }
        }
        if let standardOptionResult {
            return MSPCutConfiguration(
                operands: parsed.operands,
                selection: .bytes(MSPPOSIXRangeSpec(ranges: [])),
                delimiter: delimiter,
                outputDelimiter: outputDelimiter,
                suppressUndelimited: suppressUndelimited,
                complement: complement,
                zeroTerminated: zeroTerminated,
                standardOptionResult: standardOptionResult
            )
        }
        guard let selection else {
            throw cutFatal("you must specify a list of bytes, characters, or fields")
        }
        if selection.kind != .fields {
            if delimiterSpecified {
                throw cutFatal("an input delimiter may be specified only when operating on fields")
            }
            if suppressUndelimited {
                throw cutFatal("suppressing non-delimited lines makes sense\n\tonly when operating on fields")
            }
        }
        return MSPCutConfiguration(
            operands: parsed.operands,
            selection: selection,
            delimiter: delimiter,
            outputDelimiter: outputDelimiter,
            suppressUndelimited: suppressUndelimited,
            complement: complement,
            zeroTerminated: zeroTerminated,
            standardOptionResult: nil
        )
    }

    private func replace(_ current: MSPCutSelection?, with next: MSPCutSelection) throws -> MSPCutSelection {
        if current != nil {
            throw cutFatal("only one list may be specified")
        }
        return next
    }

    private func cutFatal(_ message: String) -> MSPCommandFailure {
        MSPCommandFailure(result: .failure(
            exitCode: 1,
            stderr: "cut: \(message)\nTry 'cut --help' for more information.\n"
        ))
    }

    private func cutRangeSpec(_ value: String, command: String, unitName: String) throws -> MSPPOSIXRangeSpec {
        let bytes = Array(value.utf8)
        let byteOrCharacterMode = unitName != "field"
        var ranges: [MSPPOSIXRangeSpec.Range] = []
        var index = 0
        var initial = 1
        var valueAccumulator = 0
        var lhsSpecified = false
        var rhsSpecified = false
        var dashFound = false

        func fail(_ message: String) throws -> Never {
            throw cutFatal(message)
        }

        func numberedFromOneMessage() -> String {
            byteOrCharacterMode ? "byte/character positions are numbered from 1" : "fields are numbered from 1"
        }

        func invalidRangeMessage() -> String {
            byteOrCharacterMode ? "invalid byte or character range" : "invalid field range"
        }

        func appendCurrentRange() throws {
            if dashFound {
                dashFound = false
                if !lhsSpecified && !rhsSpecified {
                    try fail("invalid range with no endpoint: -")
                }
                if !rhsSpecified {
                    ranges.append(.init(lower: initial, upper: Int.max))
                } else {
                    if valueAccumulator < initial {
                        try fail("invalid decreasing range")
                    }
                    ranges.append(.init(lower: initial, upper: valueAccumulator))
                }
            } else {
                if valueAccumulator == 0 {
                    try fail(numberedFromOneMessage())
                }
                ranges.append(.init(lower: valueAccumulator, upper: valueAccumulator))
            }
            valueAccumulator = 0
        }

        while true {
            let byte = index < bytes.count ? bytes[index] : 0
            if byte == 0x2d {
                if dashFound {
                    try fail(invalidRangeMessage())
                }
                dashFound = true
                index += 1
                if lhsSpecified && valueAccumulator == 0 {
                    try fail(numberedFromOneMessage())
                }
                initial = lhsSpecified ? valueAccumulator : 1
                valueAccumulator = 0
            } else if byte == 0x2c || byte == 0x20 || byte == 0x09 || byte == 0 {
                try appendCurrentRange()
                if byte == 0 {
                    break
                }
                index += 1
                lhsSpecified = false
                rhsSpecified = false
            } else if (0x30...0x39).contains(byte) {
                if dashFound {
                    rhsSpecified = true
                } else {
                    lhsSpecified = true
                }
                let digit = Int(byte - 0x30)
                if valueAccumulator > (Int.max - digit) / 10 {
                    try fail(byteOrCharacterMode ? "byte/character offset is too large" : "field number is too large")
                }
                valueAccumulator = valueAccumulator * 10 + digit
                index += 1
            } else {
                try fail(byteOrCharacterMode ? "invalid byte/character position \(value)" : "invalid field value \(value)")
            }
        }

        guard !ranges.isEmpty else {
            try fail(byteOrCharacterMode ? "missing list of byte/character positions" : "missing list of fields")
        }
        return MSPPOSIXRangeSpec(ranges: ranges)
    }

    private static let helpText = """
    Usage: cut OPTION... [FILE]...
    Print selected parts of lines from each FILE to standard output.

    With no FILE, or when FILE is -, read standard input.

      -b, --bytes=LIST        select only these bytes
      -c, --characters=LIST   select only these characters
      -d, --delimiter=DELIM   use DELIM instead of TAB for field delimiter
      -f, --fields=LIST       select only these fields
      -n                      (ignored)
          --complement        complement the set of selected bytes, characters or fields
      -s, --only-delimited    do not print lines not containing delimiters
          --output-delimiter=STRING  use STRING as the output delimiter
      -z, --zero-terminated   line delimiter is NUL, not newline
          --help        display this help and exit
          --version     output version information and exit

    GNU coreutils online help: <https://www.gnu.org/software/coreutils/>
    Full documentation <https://www.gnu.org/software/coreutils/cut>
    or available locally via: info '(coreutils) cut invocation'
    """

    private static let versionText = """
    cut (GNU coreutils) 9.1
    Copyright (C) 2022 Free Software Foundation, Inc.
    License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.
    This is free software: you are free to change and redistribute it.
    There is NO WARRANTY, to the extent permitted by law.

    Written by David M. Ihnat, David MacKenzie, and Jim Meyering.
    """
}

private struct MSPCutConfiguration {
    var operands: [String]
    var selection: MSPCutSelection
    var delimiter: UInt8
    var outputDelimiter: Data?
    var suppressUndelimited: Bool
    var complement: Bool
    var zeroTerminated: Bool
    var standardOptionResult: MSPCommandResult?
}

private enum MSPCutSelection {
    case bytes(MSPPOSIXRangeSpec)
    case characters(MSPPOSIXRangeSpec)
    case fields(MSPPOSIXRangeSpec)

    var kind: MSPCutSelectionKind {
        switch self {
        case .bytes:
            return .bytes
        case .characters:
            return .characters
        case .fields:
            return .fields
        }
    }
}

private enum MSPCutSelectionKind {
    case bytes
    case characters
    case fields
}

private func streamCutOutput(
    standardInput: any MSPCommandInputStream,
    standardOutput: any MSPCommandOutputStream,
    configuration: MSPCutConfiguration
) async throws {
    let recordDelimiter: UInt8 = configuration.zeroTerminated ? 0 : 0x0a
    var pending = Data()

    while let chunk = try await standardInput.read(maxBytes: 32 * 1024) {
        pending.append(chunk)
        while let delimiterIndex = pending.firstIndex(of: recordDelimiter) {
            let record = pending.subdata(in: pending.startIndex..<delimiterIndex)
            if let selected = try selectedCutRecord(record, configuration: configuration) {
                try await standardOutput.write(recordOutput(selected, delimiter: recordDelimiter))
            }
            pending.removeSubrange(pending.startIndex..<pending.index(after: delimiterIndex))
        }
    }
    if !pending.isEmpty,
       let selected = try selectedCutRecord(pending, configuration: configuration) {
        try await standardOutput.write(recordOutput(selected, delimiter: recordDelimiter))
    }
}

private func selectedCutRecord(_ record: Data, configuration: MSPCutConfiguration) throws -> Data? {
    switch configuration.selection {
    case .bytes(let ranges):
        return selectBytes(
            record,
            ranges: ranges,
            outputDelimiter: configuration.outputDelimiter,
            complement: configuration.complement
        )
    case .characters(let ranges):
        return selectBytes(
            record,
            ranges: ranges,
            outputDelimiter: configuration.outputDelimiter,
            complement: configuration.complement
        )
    case .fields(let ranges):
        return try selectFields(
            record,
            ranges: ranges,
            delimiter: configuration.delimiter,
            outputDelimiter: configuration.outputDelimiter,
            suppressUndelimited: configuration.suppressUndelimited,
            complement: configuration.complement
        )
    }
}

private func recordOutput(_ record: Data, delimiter: UInt8) -> Data {
    var output = record
    output.append(delimiter)
    return output
}

private func selectBytes(
    _ record: Data,
    ranges: MSPPOSIXRangeSpec,
    outputDelimiter: Data?,
    complement: Bool
) -> Data {
    let bytes = Array(record)
    var output = Data()
    appendSelectedRuns(
        count: bytes.count,
        ranges: ranges,
        outputDelimiter: outputDelimiter,
        complement: complement,
        to: &output
    ) { index, output in
        output.append(bytes[index])
    }
    return output
}

private func appendSelectedRuns(
    count: Int,
    ranges: MSPPOSIXRangeSpec,
    outputDelimiter: Data?,
    complement: Bool,
    to output: inout Data,
    appendElement: (Int, inout Data) -> Void
) {
    var printedRun = false
    for run in selectedRuns(count: count, ranges: ranges, complement: complement) {
        if printedRun, let outputDelimiter {
            output.append(outputDelimiter)
        }
        for index in run {
            appendElement(index, &output)
        }
        printedRun = true
    }
}

private func selectedRuns(count: Int, ranges: MSPPOSIXRangeSpec, complement: Bool) -> [Range<Int>] {
    guard count > 0 else { return [] }
    let normalized = normalizedRanges(count: count, ranges: ranges)
    if complement {
        var result: [Range<Int>] = []
        var nextLower = 1
        for range in normalized {
            if nextLower < range.lower {
                result.append((nextLower - 1)..<(range.lower - 1))
            }
            nextLower = max(nextLower, range.upper + 1)
        }
        if nextLower <= count {
            result.append((nextLower - 1)..<count)
        }
        return result
    }
    return normalized.map { ($0.lower - 1)..<$0.upper }
}

private func normalizedRanges(count: Int, ranges: MSPPOSIXRangeSpec) -> [MSPPOSIXRangeSpec.Range] {
    var normalized: [MSPPOSIXRangeSpec.Range] = []
    for range in ranges.ranges.sorted(by: { $0.lower < $1.lower }) {
        guard range.lower <= count else { continue }
        let lower = max(1, range.lower)
        let upper = min(count, range.upper)
        guard lower <= upper else { continue }

        if let last = normalized.last, lower <= last.upper {
            normalized[normalized.count - 1].upper = max(last.upper, upper)
        } else {
            normalized.append(MSPPOSIXRangeSpec.Range(lower: lower, upper: upper))
        }
    }
    return normalized
}

private func selectFields(
    _ record: Data,
    ranges: MSPPOSIXRangeSpec,
    delimiter: UInt8,
    outputDelimiter: Data?,
    suppressUndelimited: Bool,
    complement: Bool
) throws -> Data? {
    guard record.contains(delimiter) else {
        return suppressUndelimited ? nil : record
    }
    let fields = splitFields(record, delimiter: delimiter)
    let selectedFields = ranges.selectedOffsets(count: fields.count, complement: complement).map { fields[$0] }
    let separator = outputDelimiter ?? Data([delimiter])
    return joinDataRecords(selectedFields, separator: separator)
}

private func splitFields(_ record: Data, delimiter: UInt8) -> [Data] {
    var fields: [Data] = []
    var current = Data()
    for byte in record {
        if byte == delimiter {
            fields.append(current)
            current.removeAll(keepingCapacity: true)
        } else {
            current.append(byte)
        }
    }
    fields.append(current)
    return fields
}

private func joinedRecords(_ records: [Data], separator: Data) -> Data {
    guard !records.isEmpty else { return Data() }
    var output = Data()
    for record in records {
        output.append(record)
        output.append(separator)
    }
    return output
}

private func joinDataRecords(_ records: [Data], separator: Data) -> Data {
    guard let first = records.first else { return Data() }
    var output = first
    for record in records.dropFirst() {
        output.append(separator)
        output.append(record)
    }
    return output
}
