import Foundation
import MSPCore

public struct MSPPasteCommand: MSPStreamingCommand {
    public let name = "paste"
    public let summary: String? = "Merge corresponding or serial lines of files."

    private let spec = MSPPOSIXCommandSpec(
        name: "paste",
        allowedShortOptions: ["s", "z"],
        allowedLongOptions: ["serial", "zero-terminated", "help", "version"],
        shortOptionsRequiringValue: ["d"],
        longOptionsRequiringValue: ["delimiters"]
    )

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let standardOption = Self.standardOptionResult(arguments: invocation.arguments) {
            return standardOption
        }
        let parsed = try spec.parse(invocation.arguments)
        let serial = parsed.options.contains { $0.matches(short: "s", long: "serial") }
        let zeroTerminated = parsed.options.contains { $0.matches(short: "z", long: "zero-terminated") }
        let recordDelimiter: UInt8 = zeroTerminated ? 0 : 0x0A
        let outputRecordDelimiter = Data([recordDelimiter])
        let delimiters = try pasteDelimiters(parsed.options.lastValue(short: "d", long: "delimiters"))
        let operands = parsed.operands.isEmpty ? ["-"] : parsed.operands
        let dashCount = operands.filter { $0 == "-" }.count
        let stdinLines = dashCount > 0
            ? pasteRecords(context.standardInput, delimiter: recordDelimiter)
            : []
        var dashIndex = 0
        var columns: [[Data]] = []
        var diagnostics: [String] = []
        var exitCode: Int32 = 0
        var fileSystem: (any MSPWorkspaceFileSystem)?

        for operand in operands {
            if operand == "-" {
                defer { dashIndex += 1 }
                if serial {
                    columns.append(dashIndex == 0 ? stdinLines : [])
                } else {
                    columns.append(stride(from: dashIndex, to: stdinLines.count, by: max(dashCount, 1)).map { stdinLines[$0] })
                }
                continue
            }
            do {
                if fileSystem == nil {
                    fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
                }
                let data = try fileSystem!.readFile(operand, from: context.currentDirectory)
                columns.append(pasteRecords(data, delimiter: recordDelimiter))
            } catch {
                diagnostics.append("paste: \(MSPPOSIXCommandSupport.displayPath(operand)): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))")
                exitCode = 1
            }
        }

        let output: [Data]
        if serial {
            output = columns.map { pasteJoinWithCyclingDelimiters($0, delimiters: delimiters) }
        } else {
            let maxRows = columns.map(\.count).max() ?? 0
            output = (0..<maxRows).map { row in
                pasteJoinWithCyclingDelimiters(
                    columns.map { row < $0.count ? $0[row] : Data() },
                    delimiters: delimiters
                )
            }
        }
        return MSPCommandResult(
            stdoutData: pasteJoinedRecords(output, delimiter: outputRecordDelimiter),
            stderr: diagnostics.isEmpty ? "" : diagnostics.joined(separator: "\n") + "\n",
            exitCode: exitCode
        )
    }

    public func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let standardOption = Self.standardOptionResult(arguments: invocation.arguments) {
            return standardOption
        }
        let parsed = try spec.parse(invocation.arguments)
        guard let standardOutput = context.standardOutputStream else {
            return try await run(invocation: invocation, context: context)
        }

        let serial = parsed.options.contains { $0.matches(short: "s", long: "serial") }
        let zeroTerminated = parsed.options.contains { $0.matches(short: "z", long: "zero-terminated") }
        let recordDelimiter: UInt8 = zeroTerminated ? 0 : 0x0A
        let outputRecordDelimiter = Data([recordDelimiter])
        let delimiters = try pasteDelimiters(parsed.options.lastValue(short: "d", long: "delimiters"))
        let operands = parsed.operands.isEmpty ? ["-"] : parsed.operands

        var fileSystem: (any MSPWorkspaceFileSystem)?
        var sharedStandardInputReader: MSPPasteRecordStreamReader?
        var diagnostics: [String] = []
        var exitCode: Int32 = 0

        func makeReader(for operand: String) throws -> MSPPasteRecordStreamReader {
            if operand == "-" {
                if let sharedStandardInputReader {
                    return sharedStandardInputReader
                }
                let reader: MSPPasteRecordStreamReader
                if let standardInput = context.standardInputStream {
                    reader = MSPPasteRecordStreamReader(stream: standardInput, delimiter: recordDelimiter)
                } else {
                    reader = MSPPasteRecordStreamReader(
                        stream: MSPDataInputStream(try MSPPOSIXCommandSupport.standardInputData(from: context)),
                        delimiter: recordDelimiter
                    )
                }
                sharedStandardInputReader = reader
                return reader
            }
            if fileSystem == nil {
                fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
            }
            return MSPPasteRecordStreamReader(
                stream: MSPWorkspaceFileInputStream(
                    fileSystem: fileSystem!,
                    path: operand,
                    currentDirectory: context.currentDirectory
                ),
                delimiter: recordDelimiter
            )
        }

        if serial {
            for operand in operands {
                do {
                    let reader = try makeReader(for: operand)
                    var lineIndex = 0
                    while let line = try await reader.readRecord() {
                        if lineIndex > 0 {
                            try await standardOutput.write(delimiters[(lineIndex - 1) % delimiters.count])
                        }
                        try await standardOutput.write(line)
                        lineIndex += 1
                    }
                    try await standardOutput.write(outputRecordDelimiter)
                } catch MSPCommandStreamError.brokenPipe {
                    return .success()
                } catch {
                    diagnostics.append(
                        "paste: \(MSPPOSIXCommandSupport.displayPath(operand)): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))"
                    )
                    exitCode = 1
                }
            }
        } else {
            var readers: [MSPPasteReaderState] = []
            for operand in operands {
                do {
                    readers.append(MSPPasteReaderState(
                        operand: operand,
                        reader: try makeReader(for: operand),
                        isActive: true
                    ))
                } catch {
                    diagnostics.append(
                        "paste: \(MSPPOSIXCommandSupport.displayPath(operand)): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))"
                    )
                    exitCode = 1
                    readers.append(MSPPasteReaderState(operand: operand, reader: nil, isActive: false))
                }
            }

            while true {
                var row: [Data] = []
                var rowHasData = false
                for index in readers.indices {
                    guard readers[index].isActive, let reader = readers[index].reader else {
                        row.append(Data())
                        continue
                    }
                    do {
                        if let line = try await reader.readRecord() {
                            row.append(line)
                            rowHasData = true
                        } else {
                            readers[index].isActive = false
                            row.append(Data())
                        }
                    } catch {
                        diagnostics.append(
                            "paste: \(MSPPOSIXCommandSupport.displayPath(readers[index].operand)): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))"
                        )
                        exitCode = 1
                        readers[index].isActive = false
                        row.append(Data())
                    }
                }
                guard rowHasData else {
                    break
                }
                do {
                    var output = pasteJoinWithCyclingDelimiters(row, delimiters: delimiters)
                    output.append(outputRecordDelimiter)
                    try await standardOutput.write(output)
                } catch MSPCommandStreamError.brokenPipe {
                    return .success()
                }
            }
        }

        return MSPCommandResult(
            stderr: diagnostics.isEmpty ? "" : diagnostics.joined(separator: "\n") + "\n",
            exitCode: exitCode
        )
    }

    private static func standardOptionResult(arguments: [String]) -> MSPCommandResult? {
        if arguments.contains("--help") {
            return .success(stdout: helpText)
        }
        if arguments.contains("--version") {
            return .success(stdout: MSPPOSIXCommandSupport.gnuCoreutilsVersionText(command: "paste"))
        }
        return nil
    }

    private static let helpText = """
    Usage: paste [OPTION]... [FILE]...
    Write lines consisting of the sequentially corresponding lines from each FILE,
    separated by TABs, to standard output.

      -d, --delimiters=LIST   reuse characters from LIST instead of TABs
      -s, --serial            paste one file at a time instead of in parallel
      -z, --zero-terminated   line delimiter is NUL, not newline
          --help     display this help and exit
          --version  output version information and exit
    """
}

private struct MSPPasteReaderState {
    var operand: String
    var reader: MSPPasteRecordStreamReader?
    var isActive: Bool
}

private final class MSPPasteRecordStreamReader {
    private let stream: any MSPCommandInputStream
    private let delimiter: UInt8
    private var buffer = Data()
    private var reachedEOF = false

    init(stream: any MSPCommandInputStream, delimiter: UInt8) {
        self.stream = stream
        self.delimiter = delimiter
    }

    func readRecord(maxBytes: Int = 32 * 1024) async throws -> Data? {
        while true {
            if let delimiterIndex = buffer.firstIndex(of: delimiter) {
                let recordData = buffer.subdata(in: 0..<delimiterIndex)
                buffer.removeSubrange(0...delimiterIndex)
                return recordData
            }

            if reachedEOF {
                guard !buffer.isEmpty else {
                    return nil
                }
                let recordData = buffer
                buffer.removeAll(keepingCapacity: false)
                return recordData
            }

            if let chunk = try await stream.read(maxBytes: maxBytes) {
                buffer.append(chunk)
            } else {
                reachedEOF = true
            }
        }
    }
}

private func pasteDelimiters(_ rawValue: String?) throws -> [Data] {
    guard let rawValue else {
        return [Data([0x09])]
    }
    if rawValue.isEmpty {
        return [Data()]
    }

    var delimiters: [Data] = []
    var index = rawValue.startIndex
    while index < rawValue.endIndex {
        let character = rawValue[index]
        guard character == "\\" else {
            delimiters.append(Data(String(character).utf8))
            index = rawValue.index(after: index)
            continue
        }

        guard rawValue.index(after: index) < rawValue.endIndex else {
            throw MSPCommandFailure(result: .failure(
                exitCode: 1,
                stderr: "paste: delimiter list ends with an unescaped backslash: \(rawValue)\n"
            ))
        }

        let nextIndex = rawValue.index(after: index)
        let next = rawValue[nextIndex]
        switch next {
        case "0":
            delimiters.append(Data())
        case "b":
            delimiters.append(Data([0x08]))
        case "f":
            delimiters.append(Data([0x0C]))
        case "n":
            delimiters.append(Data([0x0A]))
        case "r":
            delimiters.append(Data([0x0D]))
        case "t":
            delimiters.append(Data([0x09]))
        case "v":
            delimiters.append(Data([0x0B]))
        case "\\":
            delimiters.append(Data([0x5C]))
        default:
            delimiters.append(Data(String(next).utf8))
        }
        index = rawValue.index(after: nextIndex)
    }
    return delimiters.isEmpty ? [Data()] : delimiters
}

private func pasteJoinWithCyclingDelimiters(_ parts: [Data], delimiters: [Data]) -> Data {
    guard let first = parts.first else { return Data() }
    let effectiveDelimiters = delimiters.isEmpty ? [Data()] : delimiters
    var output = first
    for (offset, part) in parts.dropFirst().enumerated() {
        output.append(effectiveDelimiters[offset % effectiveDelimiters.count])
        output.append(part)
    }
    return output
}

private func pasteRecords(_ data: Data, delimiter: UInt8) -> [Data] {
    mspPOSIXTextRecords(in: data, delimiter: delimiter)
}

private func pasteJoinedRecords(_ records: [Data], delimiter: Data) -> Data {
    guard !records.isEmpty else {
        return Data()
    }
    var output = records.reduce(into: Data()) { output, record in
        if !output.isEmpty {
            output.append(delimiter)
        }
        output.append(record)
    }
    output.append(delimiter)
    return output
}

private extension Array where Element == MSPPOSIXOption {
    func lastValue(short: Character, long: String) -> String? {
        reversed().first { $0.matches(short: short) || $0.matches(long: long) }?.value
    }
}
