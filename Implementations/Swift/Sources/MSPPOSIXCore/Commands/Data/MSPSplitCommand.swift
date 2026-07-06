import Foundation
import MSPCore

public struct MSPSplitCommand: MSPStreamingCommand {
    public let name = "split"
    public let summary: String? = "Split input into output files."

    private let spec = MSPPOSIXCommandSpec(
        name: "split",
        allowedShortOptions: ["e", "u"],
        allowedLongOptions: ["elide-empty-files", "unbuffered", "verbose", "help", "version"],
        shortOptionsRequiringValue: ["a", "b", "l", "n", "t", "C"],
        longOptionsRequiringValue: ["additional-suffix", "bytes", "line-bytes", "lines", "number", "separator", "suffix-length"],
        shortOptionsWithOptionalValue: ["d", "x"],
        longOptionsWithOptionalValue: ["numeric-suffixes", "hex-suffixes"]
    )

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") {
            return .success(stdout: mspSplitUsageText)
        }
        if invocation.arguments.contains("--version") {
            return .success(stdout: "split (GNU coreutils) 9.1\n")
        }
        let options = try parse(invocation.arguments)
        return try await split(options: options, context: context, inputStream: context.standardInputStream)
    }

    public func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") || invocation.arguments.contains("--version") {
            return try await run(invocation: invocation, context: context)
        }
        let options = try parse(invocation.arguments)
        return try await split(options: options, context: context, inputStream: context.standardInputStream)
    }

    private func parse(_ arguments: [String]) throws -> MSPSplitOptions {
        let parsed: MSPPOSIXParsedArguments
        do {
            parsed = try spec.parse(arguments)
        } catch let failure as MSPCommandFailure {
            throw failure
        }

        var options = MSPSplitOptions()
        var splitTypeWasSet = false

        func setSplitType(_ splitType: MSPSplitType) throws {
            guard !splitTypeWasSet else {
                throw MSPCommandFailure(result: .failure(
                    exitCode: 1,
                    stderr: "split: cannot split in more than one way\nTry 'split --help' for more information.\n"
                ))
            }
            options.splitType = splitType
            splitTypeWasSet = true
        }

        for option in parsed.options {
            switch option.name {
            case .short("a"), .long("suffix-length"):
                guard let value = option.value, let length = Int(value), length >= 0 else {
                    throw MSPCommandFailure(result: .failure(
                        exitCode: 1,
                        stderr: "split: invalid suffix length: \(MSPPOSIXCommandSupport.gnuQuote(option.value ?? ""))\n"
                    ))
                }
                options.suffixLength = length
            case .short("b"), .long("bytes"):
                let rawValue = option.value ?? ""
                guard let count = mspSplitSize(rawValue) else {
                    throw MSPCommandFailure(result: .failure(
                        exitCode: 1,
                        stderr: "split: invalid number of bytes: \(MSPPOSIXCommandSupport.gnuQuote(rawValue))\n"
                    ))
                }
                try setSplitType(.bytes(count))
            case .short("C"), .long("line-bytes"):
                let rawValue = option.value ?? ""
                guard let count = mspSplitSize(rawValue) else {
                    throw MSPCommandFailure(result: .failure(
                        exitCode: 1,
                        stderr: "split: invalid number of bytes: \(MSPPOSIXCommandSupport.gnuQuote(rawValue))\n"
                    ))
                }
                try setSplitType(.lineBytes(count))
            case .short("l"), .long("lines"):
                let rawValue = option.value ?? ""
                guard let count = Int(rawValue), count > 0 else {
                    throw MSPCommandFailure(result: .failure(
                        exitCode: 1,
                        stderr: "split: invalid number of lines: \(MSPPOSIXCommandSupport.gnuQuote(rawValue))\n"
                    ))
                }
                try setSplitType(.lines(count))
            case .short("n"), .long("number"):
                let rawValue = option.value ?? ""
                if rawValue.hasPrefix("r/") {
                    let countText = String(rawValue.dropFirst(2))
                    guard let count = Int(countText), count > 0 else {
                        throw MSPCommandFailure(result: .failure(
                            exitCode: 1,
                            stderr: "split: invalid number of chunks: \(MSPPOSIXCommandSupport.gnuQuote(countText))\n"
                        ))
                    }
                    try setSplitType(.roundRobin(count))
                } else {
                    guard let count = Int(rawValue), count > 0 else {
                        throw MSPCommandFailure(result: .failure(
                            exitCode: 1,
                            stderr: "split: invalid number of chunks: \(MSPPOSIXCommandSupport.gnuQuote(rawValue))\n"
                        ))
                    }
                    try setSplitType(.chunks(count))
                }
            case .short("d"), .long("numeric-suffixes"):
                options.suffixKind = .numeric
                if let value = option.value, !value.isEmpty {
                    options.suffixStart = try mspSplitSuffixStart(value, option: "numeric")
                }
            case .short("x"), .long("hex-suffixes"):
                options.suffixKind = .hex
                if let value = option.value, !value.isEmpty {
                    options.suffixStart = try mspSplitSuffixStart(value, option: "hex")
                }
            case .long("additional-suffix"):
                options.additionalSuffix = option.value ?? ""
            case .short("e"), .long("elide-empty-files"):
                options.elideEmptyFiles = true
            case .short("u"), .long("unbuffered"):
                options.unbuffered = true
            case .long("verbose"):
                options.verbose = true
            case .short("t"), .long("separator"):
                let value = option.value ?? ""
                options.separator = value == "\\0" ? 0 : (value.utf8.first ?? 0x0A)
            default:
                continue
            }
        }

        if parsed.operands.indices.contains(0) {
            options.inputPath = parsed.operands[0]
        }
        if parsed.operands.indices.contains(1) {
            options.prefix = parsed.operands[1]
        }
        if parsed.operands.count > 2 {
            throw MSPCommandFailure.usage("split: extra operand \(MSPPOSIXCommandSupport.gnuQuote(parsed.operands[2]))\n")
        }

        return options
    }

    private func split(
        options: MSPSplitOptions,
        context: MSPCommandContext,
        inputStream: (any MSPCommandInputStream)?
    ) async throws -> MSPCommandResult {
        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        var reader: MSPSplitInputReader
        do {
            reader = try makeReader(options: options, context: context, fileSystem: fileSystem, inputStream: inputStream)
        } catch {
            return MSPCommandResult(
                stderr: "split: cannot open '\(options.inputPath)' for reading: \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n",
                exitCode: 1
            )
        }

        var writer = MSPSplitWriter(
            fileSystem: fileSystem,
            currentDirectory: context.currentDirectory,
            prefix: options.prefix,
            suffixLength: options.suffixLength,
            suffixKind: options.suffixKind,
            additionalSuffix: options.additionalSuffix,
            verbose: options.verbose,
            creationMode: context.regularFileCreationMode,
            nextIndex: options.suffixStart
        )

        switch options.splitType {
        case .bytes(let count):
            try await splitBytes(count, reader: &reader, writer: &writer)
        case .lineBytes(let count):
            try await splitLineBytes(count, separator: options.separator, reader: &reader, writer: &writer)
        case .lines(let count):
            try await splitLines(count, separator: options.separator, reader: &reader, writer: &writer)
        case .roundRobin(let count):
            try await splitRoundRobin(count, separator: options.separator, elideEmpty: options.elideEmptyFiles, reader: &reader, writer: &writer)
        case .chunks:
            if options.inputPath == "-" {
                return MSPCommandResult(stderr: "split: -: cannot determine file size\n", exitCode: 1)
            }
            try await splitFixedChunks(options: options, reader: &reader, writer: &writer)
        }

        return .success(stdout: writer.stdout)
    }

    private func makeReader(
        options: MSPSplitOptions,
        context: MSPCommandContext,
        fileSystem: any MSPWorkspaceFileSystem,
        inputStream: (any MSPCommandInputStream)?
    ) throws -> MSPSplitInputReader {
        if options.inputPath != "-" {
            _ = try fileSystem.stat(options.inputPath, from: context.currentDirectory)
            return .file(MSPSplitFileReader(
                fileSystem: fileSystem,
                path: options.inputPath,
                currentDirectory: context.currentDirectory
            ))
        }
        if let inputStream {
            return .stream(MSPSplitStreamReader(stream: inputStream))
        }
        let data = try MSPPOSIXCommandSupport.standardInputData(from: context)
        return .data(MSPSplitDataReader(data: data))
    }

    private func splitBytes(
        _ byteCount: Int,
        reader: inout MSPSplitInputReader,
        writer: inout MSPSplitWriter
    ) async throws {
        var remainingInFile = byteCount
        var currentFile: String?
        while let chunk = try await reader.read(maxBytes: 32 * 1024) {
            var start = 0
            while start < chunk.count {
                if currentFile == nil {
                    currentFile = try writer.nextFile()
                    remainingInFile = byteCount
                }
                let length = min(remainingInFile, chunk.count - start)
                try writer.append(chunk.subdata(in: start..<(start + length)), to: currentFile!)
                start += length
                remainingInFile -= length
                if remainingInFile == 0 {
                    currentFile = nil
                }
            }
        }
    }

    private func splitLineBytes(
        _ byteCount: Int,
        separator: UInt8,
        reader: inout MSPSplitInputReader,
        writer: inout MSPSplitWriter
    ) async throws {
        var currentFile: String?
        var bytesInCurrent = 0
        var currentRecord = Data()
        func flushRecord() throws {
            guard !currentRecord.isEmpty else { return }
            if currentFile == nil || (bytesInCurrent > 0 && bytesInCurrent + currentRecord.count > byteCount) {
                currentFile = try writer.nextFile()
                bytesInCurrent = 0
            }
            try writer.append(currentRecord, to: currentFile!)
            bytesInCurrent += currentRecord.count
            currentRecord.removeAll(keepingCapacity: true)
        }
        while let chunk = try await reader.read(maxBytes: 32 * 1024) {
            for byte in chunk {
                currentRecord.append(byte)
                if byte == separator {
                    try flushRecord()
                }
            }
        }
        try flushRecord()
    }

    private func splitLines(
        _ lineCount: Int,
        separator: UInt8,
        reader: inout MSPSplitInputReader,
        writer: inout MSPSplitWriter
    ) async throws {
        var currentFile: String?
        var linesInCurrent = 0
        while let chunk = try await reader.read(maxBytes: 32 * 1024) {
            var segmentStart = 0
            for index in chunk.indices where chunk[index] == separator {
                if currentFile == nil {
                    currentFile = try writer.nextFile()
                }
                let end = index + 1
                try writer.append(chunk.subdata(in: segmentStart..<end), to: currentFile!)
                segmentStart = end
                linesInCurrent += 1
                if linesInCurrent >= lineCount {
                    currentFile = nil
                    linesInCurrent = 0
                }
            }
            if segmentStart < chunk.count {
                if currentFile == nil {
                    currentFile = try writer.nextFile()
                }
                try writer.append(chunk.subdata(in: segmentStart..<chunk.count), to: currentFile!)
            }
        }
    }

    private func splitRoundRobin(
        _ fileCount: Int,
        separator: UInt8,
        elideEmpty: Bool,
        reader: inout MSPSplitInputReader,
        writer: inout MSPSplitWriter
    ) async throws {
        let files = try (0..<fileCount).map { _ in try writer.nextFile(createEmpty: !elideEmpty) }
        var currentRecord = Data()
        var recordIndex = 0
        while let chunk = try await reader.read(maxBytes: 32 * 1024) {
            for byte in chunk {
                currentRecord.append(byte)
                if byte == separator {
                    try writer.append(currentRecord, to: files[recordIndex % fileCount])
                    currentRecord.removeAll(keepingCapacity: true)
                    recordIndex += 1
                }
            }
        }
        if !currentRecord.isEmpty {
            try writer.append(currentRecord, to: files[recordIndex % fileCount])
        }
    }

    private func splitFixedChunks(
        options: MSPSplitOptions,
        reader: inout MSPSplitInputReader,
        writer: inout MSPSplitWriter
    ) async throws {
        let data = try await reader.readAllForSizedChunk()
        guard case .chunks(let count) = options.splitType else {
            return
        }
        let chunkSize = max(1, data.count / count)
        var offset = 0
        for index in 0..<count {
            let file = try writer.nextFile(createEmpty: !options.elideEmptyFiles)
            let remainingFiles = count - index
            let remainingBytes = data.count - offset
            let length = index == count - 1 ? remainingBytes : min(chunkSize, max(0, remainingBytes - (remainingFiles - 1) * chunkSize))
            if length > 0 {
                try writer.append(data.subdata(in: offset..<(offset + length)), to: file)
                offset += length
            }
        }
    }
}

private struct MSPSplitOptions {
    var splitType: MSPSplitType = .lines(1000)
    var inputPath = "-"
    var prefix = "x"
    var suffixLength = 2
    var suffixKind: MSPSplitSuffixKind = .alphabetic
    var additionalSuffix = ""
    var separator: UInt8 = 0x0A
    var verbose = false
    var elideEmptyFiles = false
    var unbuffered = false
    var suffixStart = 0
}

private enum MSPSplitType {
    case bytes(Int)
    case lineBytes(Int)
    case lines(Int)
    case roundRobin(Int)
    case chunks(Int)
}

private enum MSPSplitSuffixKind {
    case alphabetic
    case numeric
    case hex
}

private enum MSPSplitInputReader {
    case data(MSPSplitDataReader)
    case file(MSPSplitFileReader)
    case stream(MSPSplitStreamReader)

    mutating func read(maxBytes: Int) async throws -> Data? {
        switch self {
        case .data(var reader):
            let chunk = try await reader.read(maxBytes: maxBytes)
            self = .data(reader)
            return chunk
        case .file(var reader):
            let chunk = try await reader.read(maxBytes: maxBytes)
            self = .file(reader)
            return chunk
        case .stream(var reader):
            let chunk = try await reader.read(maxBytes: maxBytes)
            self = .stream(reader)
            return chunk
        }
    }

    mutating func readAllForSizedChunk() async throws -> Data {
        var data = Data()
        while let chunk = try await read(maxBytes: 32 * 1024) {
            data.append(chunk)
        }
        return data
    }
}

private struct MSPSplitDataReader {
    var data: Data
    var offset = 0

    mutating func read(maxBytes: Int) async throws -> Data? {
        guard offset < data.count else {
            return nil
        }
        let end = min(data.count, offset + maxBytes)
        let chunk = data.subdata(in: offset..<end)
        offset = end
        return chunk
    }
}

private struct MSPSplitFileReader {
    var fileSystem: any MSPWorkspaceFileSystem
    var path: String
    var currentDirectory: String
    var offset: UInt64 = 0

    mutating func read(maxBytes: Int) async throws -> Data? {
        let chunk = try fileSystem.readFileRange(path, from: currentDirectory, offset: offset, length: maxBytes)
        guard !chunk.isEmpty else {
            return nil
        }
        offset += UInt64(chunk.count)
        return chunk
    }
}

private struct MSPSplitStreamReader {
    var stream: any MSPCommandInputStream

    mutating func read(maxBytes: Int) async throws -> Data? {
        try await stream.read(maxBytes: maxBytes)
    }
}

private struct MSPSplitWriter {
    var fileSystem: any MSPWorkspaceFileSystem
    var currentDirectory: String
    var prefix: String
    var suffixLength: Int
    var suffixKind: MSPSplitSuffixKind
    var additionalSuffix: String
    var verbose: Bool
    var creationMode: UInt16
    var nextIndex: Int
    var stdout = ""
    var created = Set<String>()

    mutating func nextFile(createEmpty: Bool = false) throws -> String {
        let fileName = prefix + suffix(for: nextIndex) + additionalSuffix
        nextIndex += 1
        if createEmpty {
            try create(fileName)
        }
        return fileName
    }

    mutating func append(_ data: Data, to fileName: String) throws {
        if !created.contains(fileName) {
            try create(fileName)
        }
        guard !data.isEmpty else {
            return
        }
        try fileSystem.appendFile(
            fileName,
            data: data,
            from: currentDirectory,
            options: [.createParentDirectories],
            creationMode: creationMode
        )
    }

    private mutating func create(_ fileName: String) throws {
        guard !created.contains(fileName) else {
            return
        }
        try fileSystem.writeFile(
            fileName,
            data: Data(),
            from: currentDirectory,
            options: [.overwriteExisting, .createParentDirectories],
            creationMode: creationMode
        )
        created.insert(fileName)
        if verbose {
            stdout += "creating file '\(fileName)'\n"
        }
    }

    private func suffix(for index: Int) -> String {
        switch suffixKind {
        case .alphabetic:
            return encoded(index, alphabet: Array("abcdefghijklmnopqrstuvwxyz"), width: suffixLength)
        case .numeric:
            return encoded(index, alphabet: Array("0123456789"), width: suffixLength)
        case .hex:
            return encoded(index, alphabet: Array("0123456789abcdef"), width: suffixLength)
        }
    }

    private func encoded(_ value: Int, alphabet: [Character], width: Int) -> String {
        guard width > 0 else {
            return ""
        }
        var digits = Array(repeating: alphabet[0], count: width)
        var remaining = value
        for position in stride(from: width - 1, through: 0, by: -1) {
            digits[position] = alphabet[remaining % alphabet.count]
            remaining /= alphabet.count
        }
        return String(digits)
    }
}

private func mspSplitSize(_ rawValue: String) -> Int? {
    guard !rawValue.isEmpty else { return nil }
    let suffix = rawValue.last!
    let numberText: Substring
    let multiplier: Int
    switch suffix {
    case "K":
        numberText = rawValue.dropLast()
        multiplier = 1024
    case "M":
        numberText = rawValue.dropLast()
        multiplier = 1024 * 1024
    case "G":
        numberText = rawValue.dropLast()
        multiplier = 1024 * 1024 * 1024
    case "k":
        numberText = rawValue.dropLast()
        multiplier = 1000
    default:
        numberText = Substring(rawValue)
        multiplier = 1
    }
    guard let value = Int(numberText), value > 0 else {
        return nil
    }
    let (result, overflow) = value.multipliedReportingOverflow(by: multiplier)
    return overflow ? nil : result
}

private func mspSplitSuffixStart(_ rawValue: String, option: String) throws -> Int {
    guard let value = Int(rawValue), value >= 0 else {
        throw MSPCommandFailure(result: .failure(
            exitCode: 1,
            stderr: "split: invalid \(option) suffix start: \(MSPPOSIXCommandSupport.gnuQuote(rawValue))\n"
        ))
    }
    return value
}

private let mspSplitUsageText = """
Usage: split [OPTION]... [FILE [PREFIX]]
Output pieces of FILE to PREFIXaa, PREFIXab, ...; default size is 1000 lines.

  -a, --suffix-length=N   generate suffixes of length N
      --additional-suffix=SUFFIX  append an additional SUFFIX
  -b, --bytes=SIZE        put SIZE bytes per output file
  -C, --line-bytes=SIZE   put at most SIZE bytes of records per output file
  -d, --numeric-suffixes[=FROM]  use numeric suffixes
  -x, --hex-suffixes[=FROM]      use hexadecimal suffixes
  -e, --elide-empty-files do not generate empty output files with -n
  -l, --lines=NUMBER      put NUMBER lines per output file
  -n, --number=CHUNKS     generate CHUNKS output files
  -t, --separator=SEP     use SEP instead of newline as the record separator
  -u, --unbuffered        immediately copy input to output with -n r/...
      --verbose           print a diagnostic before each output file is opened
      --help        display this help and exit
      --version     output version information and exit

"""
