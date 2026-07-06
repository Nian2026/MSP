import Foundation
import MSPCore

public struct MSPUniqCommand: MSPStreamingCommand {
    public let name = "uniq"
    public let summary: String? = "Report or filter adjacent repeated records."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") {
            return .success(stdout: mspUniqHelp())
        }
        if invocation.arguments.contains("--version") {
            return .success(stdout: "uniq (GNU coreutils) 9.1\n")
        }
        let parsed = try parse(invocation.arguments)
        let inputResult = try await MSPPOSIXCommandSupport.inputData(
            operands: parsed.inputOperands,
            context: context,
            command: name
        )
        let data = inputResult.inputs.reduce(into: Data()) { output, input in output.append(input.data) }
        let delimiter: UInt8 = parsed.options.zeroTerminated ? 0 : 0x0A
        let records = mspPOSIXTextRecords(in: data, delimiter: delimiter)
        let output = uniqOutput(records, options: parsed.options, delimiter: delimiter)
        let stderr = inputResult.diagnostics.isEmpty ? "" : inputResult.diagnostics.joined(separator: "\n") + "\n"
        if let outputPath = parsed.outputPath {
            let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
            try fileSystem.writeFile(
                outputPath,
                data: output,
                from: context.currentDirectory,
                options: [.overwriteExisting, .createParentDirectories],
                creationMode: context.regularFileCreationMode
            )
            return MSPCommandResult(stderr: stderr, exitCode: inputResult.exitCode)
        }
        return MSPCommandResult(
            stdoutData: output,
            stderr: stderr,
            exitCode: inputResult.exitCode
        )
    }

    public func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") || invocation.arguments.contains("--version") {
            return try await run(invocation: invocation, context: context)
        }
        let parsed = try parse(invocation.arguments)
        guard parsed.outputPath == nil,
              parsed.inputOperands.isEmpty || parsed.inputOperands == ["-"],
              let standardInput = context.standardInputStream,
              let standardOutput = context.standardOutputStream
        else {
            return try await run(invocation: invocation, context: context)
        }

        do {
            try await streamUniqOutput(
                standardInput: standardInput,
                standardOutput: standardOutput,
                options: parsed.options
            )
        } catch MSPCommandStreamError.brokenPipe {
            return .success()
        }
        return .success()
    }

    private func parse(_ arguments: [String]) throws -> ParsedUniqInvocation {
        let spec = MSPPOSIXCommandSpec(
            name: name,
            allowedShortOptions: ["c", "d", "D", "u", "i", "z"],
            allowedLongOptions: [
                "count",
                "repeated",
                "all-repeated",
                "unique",
                "ignore-case",
                "zero-terminated",
                "group",
                "help",
                "version"
            ],
            shortOptionsRequiringValue: ["w", "f", "s"],
            longOptionsRequiringValue: ["check-chars", "skip-fields", "skip-chars"],
            longOptionsWithOptionalValue: ["all-repeated", "group"]
        )
        let parsed = try spec.parse(normalizeObsoleteUniqOptions(arguments))
        try spec.requireOperandCount(parsed.operands, max: 2)
        var options = UniqOptions()
        var outputOptionUsed = false
        for option in parsed.options {
            switch option.name {
            case .short("c"), .long("count"):
                options.includeCount = true
                outputOptionUsed = true
            case .short("d"), .long("repeated"):
                options.repeatedOnly = true
                outputOptionUsed = true
            case .short("D"), .long("all-repeated"):
                options.allRepeated = true
                options.allRepeatedDelimiter = try allRepeatedDelimiter(option.value)
                outputOptionUsed = true
            case .short("u"), .long("unique"):
                options.uniqueOnly = true
                outputOptionUsed = true
            case .short("i"), .long("ignore-case"):
                options.ignoreCase = true
            case .short("z"), .long("zero-terminated"):
                options.zeroTerminated = true
            case .long("group"):
                options.grouping = try uniqGrouping(option.value)
            case .short("w"), .long("check-chars"):
                options.checkChars = try nonNegativeInteger(option.value, command: name, option: option)
            case .short("f"), .long("skip-fields"):
                options.skipFields = try nonNegativeInteger(option.value, command: name, option: option)
            case .short("s"), .long("skip-chars"):
                options.skipChars = try nonNegativeInteger(option.value, command: name, option: option)
            default:
                continue
            }
        }
        if options.grouping != .none, outputOptionUsed {
            throw MSPCommandFailure(result: .failure(
                exitCode: 1,
                stderr: """
                uniq: --group is mutually exclusive with -c/-d/-D/-u
                Try 'uniq --help' for more information.

                """
            ))
        }

        return ParsedUniqInvocation(
            options: options,
            inputOperands: parsed.operands.first.map { [$0] } ?? [],
            outputPath: parsed.operands.dropFirst().first
        )
    }

    private func nonNegativeInteger(
        _ rawValue: String?,
        command: String,
        option: MSPPOSIXOption
    ) throws -> Int {
        guard let rawValue,
              let value = Int(rawValue),
              value >= 0 else {
            let description: String
            switch option.name {
            case .short("w"), .long("check-chars"):
                description = "bytes to compare"
            case .short("f"), .long("skip-fields"):
                description = "fields to skip"
            case .short("s"), .long("skip-chars"):
                description = "bytes to skip"
            default:
                description = "number"
            }
            throw MSPCommandFailure(result: .failure(
                exitCode: 1,
                stderr: "\(command): \(rawValue ?? ""): invalid number of \(description)\n"
            ))
        }
        return value
    }
}

private func normalizeObsoleteUniqOptions(_ arguments: [String]) -> [String] {
    var normalized: [String] = []
    for argument in arguments {
        if argument.count > 1,
           argument.first == "-",
           argument.dropFirst().allSatisfy(\.isNumber) {
            normalized.append("-f")
            normalized.append(String(argument.dropFirst()))
        } else if argument.count > 1,
                  argument.first == "+",
                  argument.dropFirst().allSatisfy(\.isNumber) {
            normalized.append("-s")
            normalized.append(String(argument.dropFirst()))
        } else {
            normalized.append(argument)
        }
    }
    return normalized
}

private func mspUniqHelp() -> String {
    """
    Usage: uniq [OPTION]... [INPUT [OUTPUT]]
    Filter adjacent matching lines from INPUT, writing to OUTPUT.

      -c, --count                 prefix lines by the number of occurrences
      -d, --repeated              only print duplicate lines, one for each group
      -D, --all-repeated[=METHOD] print all duplicate lines
      -f, --skip-fields=N         avoid comparing the first N fields
          --group[=METHOD]        show all items, separating groups with an empty line
      -i, --ignore-case           ignore differences in case
      -s, --skip-chars=N          avoid comparing the first N characters
      -u, --unique                only print unique lines
      -w, --check-chars=N         compare no more than N characters in lines
      -z, --zero-terminated       line delimiter is NUL, not newline
          --help                  display this help and exit
          --version               output version information and exit

    """
}

private struct ParsedUniqInvocation {
    var options: UniqOptions
    var inputOperands: [String]
    var outputPath: String?
}

private struct UniqOptions {
    var includeCount = false
    var repeatedOnly = false
    var allRepeated = false
    var uniqueOnly = false
    var ignoreCase = false
    var zeroTerminated = false
    var allRepeatedDelimiter: UniqAllRepeatedDelimiter = .none
    var grouping: UniqGrouping = .none
    var skipFields = 0
    var skipChars = 0
    var checkChars: Int?
}

private enum UniqAllRepeatedDelimiter {
    case none
    case prepend
    case separate
}

private enum UniqGrouping {
    case none
    case prepend
    case append
    case separate
    case both
}

private func allRepeatedDelimiter(_ value: String?) throws -> UniqAllRepeatedDelimiter {
    switch value {
    case nil, "none":
        return .none
    case "prepend":
        return .prepend
    case "separate":
        return .separate
    default:
        throw MSPCommandFailure(result: .failure(
            exitCode: 1,
            stderr: """
            uniq: invalid argument \(MSPPOSIXCommandSupport.gnuQuote(value ?? "")) for \(MSPPOSIXCommandSupport.gnuQuote("--all-repeated"))
            Valid arguments are:
              - \(MSPPOSIXCommandSupport.gnuQuote("none"))
              - \(MSPPOSIXCommandSupport.gnuQuote("prepend"))
              - \(MSPPOSIXCommandSupport.gnuQuote("separate"))
            Try 'uniq --help' for more information.

            """
        ))
    }
}

private func uniqGrouping(_ value: String?) throws -> UniqGrouping {
    switch value {
    case nil, "separate":
        return .separate
    case "prepend":
        return .prepend
    case "append":
        return .append
    case "both":
        return .both
    default:
        throw MSPCommandFailure(result: .failure(
            exitCode: 1,
            stderr: """
            uniq: invalid argument \(MSPPOSIXCommandSupport.gnuQuote(value ?? "")) for \(MSPPOSIXCommandSupport.gnuQuote("--group"))
            Valid arguments are:
              - \(MSPPOSIXCommandSupport.gnuQuote("prepend"))
              - \(MSPPOSIXCommandSupport.gnuQuote("append"))
              - \(MSPPOSIXCommandSupport.gnuQuote("separate"))
              - \(MSPPOSIXCommandSupport.gnuQuote("both"))
            Try 'uniq --help' for more information.

            """
        ))
    }
}

private struct UniqStreamingState {
    var options: UniqOptions
    var delimiter: UInt8
    private var currentRun: [Data] = []
    private var firstGroupPrinted = false

    init(options: UniqOptions, delimiter: UInt8) {
        self.options = options
        self.delimiter = delimiter
    }

    mutating func append(_ record: Data, to output: any MSPCommandOutputStream) async throws {
        if let first = currentRun.first,
           uniqComparisonKey(record, options: options) != uniqComparisonKey(first, options: options) {
            try await flush(to: output, isFinal: false)
            currentRun = []
        }
        currentRun.append(record)
    }

    mutating func finish(to output: any MSPCommandOutputStream) async throws {
        try await flush(to: output, isFinal: true)
    }

    private mutating func flush(to output: any MSPCommandOutputStream, isFinal: Bool) async throws {
        guard let first = currentRun.first else {
            return
        }
        let runCount = currentRun.count
        if options.grouping != .none {
            try await writeGroupPrefixIfNeeded(to: output)
            for record in currentRun {
                try await output.write(uniqRecordOutput(
                    record,
                    runCount: runCount,
                    includeCount: false,
                    delimiter: delimiter
                ))
            }
            firstGroupPrinted = true
            if options.grouping == .append || (options.grouping == .both && isFinal) {
                try await output.write(Data([delimiter]))
            }
            currentRun = []
            return
        }
        if options.repeatedOnly, runCount < 2 {
            currentRun = []
            return
        }
        if options.uniqueOnly, runCount != 1 {
            currentRun = []
            return
        }
        if options.allRepeated, runCount < 2 {
            currentRun = []
            return
        }
        if options.allRepeated {
            if options.allRepeatedDelimiter == .prepend
                || (options.allRepeatedDelimiter == .separate && firstGroupPrinted) {
                try await output.write(Data([delimiter]))
            }
            for record in currentRun {
                try await output.write(uniqRecordOutput(
                    record,
                    runCount: runCount,
                    includeCount: options.includeCount,
                    delimiter: delimiter
                ))
            }
            firstGroupPrinted = true
        } else {
            try await output.write(uniqRecordOutput(
                first,
                runCount: runCount,
                includeCount: options.includeCount,
                delimiter: delimiter
            ))
        }
        currentRun = []
    }

    private mutating func writeGroupPrefixIfNeeded(to output: any MSPCommandOutputStream) async throws {
        switch options.grouping {
        case .prepend, .both:
            try await output.write(Data([delimiter]))
        case .separate:
            if firstGroupPrinted {
                try await output.write(Data([delimiter]))
            }
        case .append, .none:
            break
        }
    }
}

private func streamUniqOutput(
    standardInput: any MSPCommandInputStream,
    standardOutput: any MSPCommandOutputStream,
    options: UniqOptions
) async throws {
    let delimiter: UInt8 = options.zeroTerminated ? 0 : 0x0A
    var pending = Data()
    var state = UniqStreamingState(options: options, delimiter: delimiter)

    while let chunk = try await standardInput.read(maxBytes: 32 * 1024) {
        pending.append(chunk)
        while let delimiterIndex = pending.firstIndex(of: delimiter) {
            let record = pending.subdata(in: pending.startIndex..<delimiterIndex)
            try await state.append(record, to: standardOutput)
            pending.removeSubrange(pending.startIndex..<pending.index(after: delimiterIndex))
        }
    }
    if !pending.isEmpty {
        try await state.append(pending, to: standardOutput)
    }
    try await state.finish(to: standardOutput)
}

private func uniqOutput(_ records: [Data], options: UniqOptions, delimiter: UInt8) -> Data {
    var output = Data()
    var currentRun: [Data] = []
    var firstGroupPrinted = false

    func flush(isFinal: Bool) {
        guard let first = currentRun.first else {
            return
        }
        let runCount = currentRun.count
        if options.grouping != .none {
            appendGroupPrefixIfNeeded(
                grouping: options.grouping,
                delimiter: delimiter,
                firstGroupPrinted: firstGroupPrinted,
                to: &output
            )
            for record in currentRun {
                appendUniqRecord(
                    record,
                    runCount: runCount,
                    includeCount: false,
                    delimiter: delimiter,
                    to: &output
                )
            }
            firstGroupPrinted = true
            if options.grouping == .append || (options.grouping == .both && isFinal) {
                output.append(delimiter)
            }
            return
        }
        if options.repeatedOnly, runCount < 2 {
            return
        }
        if options.uniqueOnly, runCount != 1 {
            return
        }
        if options.allRepeated, runCount < 2 {
            return
        }
        if options.allRepeated {
            if options.allRepeatedDelimiter == .prepend
                || (options.allRepeatedDelimiter == .separate && firstGroupPrinted) {
                output.append(delimiter)
            }
            for record in currentRun {
                appendUniqRecord(
                    record,
                    runCount: runCount,
                    includeCount: options.includeCount,
                    delimiter: delimiter,
                    to: &output
                )
            }
            firstGroupPrinted = true
        } else {
            appendUniqRecord(
                first,
                runCount: runCount,
                includeCount: options.includeCount,
                delimiter: delimiter,
                to: &output
            )
        }
    }

    for record in records {
        if let first = currentRun.first,
           uniqComparisonKey(record, options: options) == uniqComparisonKey(first, options: options) {
            currentRun.append(record)
        } else {
            flush(isFinal: false)
            currentRun = [record]
        }
    }
    flush(isFinal: true)
    return output
}

private func appendGroupPrefixIfNeeded(
    grouping: UniqGrouping,
    delimiter: UInt8,
    firstGroupPrinted: Bool,
    to output: inout Data
) {
    switch grouping {
    case .prepend, .both:
        output.append(delimiter)
    case .separate:
        if firstGroupPrinted {
            output.append(delimiter)
        }
    case .append, .none:
        break
    }
}

private func uniqComparisonKey(_ record: Data, options: UniqOptions) -> UniqComparisonKey {
    guard options.skipFields > 0 || options.skipChars > 0 || options.checkChars != nil || options.ignoreCase else {
        return .bytes(record)
    }
    var key = uniqComparableBytes(record, options: options)
    if let checkChars = options.checkChars {
        key = key.prefix(checkChars)
    }
    if options.ignoreCase {
        key = asciiCaseFoldedBytes(key)
    }
    return .bytes(key)
}

private func uniqComparableBytes(_ record: Data, options: UniqOptions) -> Data {
    var offset = record.startIndex
    if options.skipFields > 0 {
        for _ in 0..<options.skipFields {
            while offset < record.endIndex, uniqFieldSeparator(record[offset]) {
                offset = record.index(after: offset)
            }
            while offset < record.endIndex, !uniqFieldSeparator(record[offset]) {
                offset = record.index(after: offset)
            }
        }
    }
    offset = min(record.endIndex, offset + options.skipChars)
    return record.subdata(in: offset..<record.endIndex)
}

private func uniqFieldSeparator(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0a
}

private enum UniqComparisonKey: Equatable {
    case bytes(Data)
}

private func asciiCaseFoldedBytes(_ bytes: Data) -> Data {
    Data(bytes.map { byte in
        (0x41...0x5a).contains(byte) ? byte + 0x20 : byte
    })
}

private func appendUniqRecord(
    _ record: Data,
    runCount: Int,
    includeCount: Bool,
    delimiter: UInt8,
    to output: inout Data
) {
    output.append(uniqRecordOutput(
        record,
        runCount: runCount,
        includeCount: includeCount,
        delimiter: delimiter
    ))
}

private func uniqRecordOutput(
    _ record: Data,
    runCount: Int,
    includeCount: Bool,
    delimiter: UInt8
) -> Data {
    var output = Data()
    if includeCount {
        output.append(contentsOf: String(format: "%7d ", runCount).utf8)
    }
    output.append(record)
    output.append(delimiter)
    return output
}
