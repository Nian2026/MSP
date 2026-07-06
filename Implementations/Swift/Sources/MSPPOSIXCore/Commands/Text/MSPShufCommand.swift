import Foundation
import MSPCore

public struct MSPShufCommand: MSPCommand {
    public let name = "shuf"
    public let summary: String? = "Generate random permutations."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") {
            return .success(stdout: mspShufUsageText)
        }
        if invocation.arguments.contains("--version") {
            return .success(stdout: "shuf (GNU coreutils) 9.1\n")
        }
        let options = try parse(invocation.arguments)
        let fileSystem = context.workspace?.fileSystem
        var random = try makeRandomSource(options.randomSource, fileSystem: fileSystem, context: context)

        let output: Data
        do {
            output = try generateOutput(options: options, context: context, fileSystem: fileSystem, random: &random)
        } catch let error as MSPShufReadError {
            return MSPCommandResult(
                stderr: "shuf: \(error.path): \(MSPPOSIXCommandSupport.diagnosticReason(from: error.underlying))\n",
                exitCode: 1
            )
        }

        if let outputPath = options.outputPath {
            let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
            try fileSystem.writeFile(
                outputPath,
                data: output,
                from: context.currentDirectory,
                options: [.overwriteExisting, .createParentDirectories],
                creationMode: context.regularFileCreationMode
            )
            return .success()
        }
        return .success(stdoutData: output)
    }

    private func parse(_ arguments: [String]) throws -> MSPShufOptions {
        var options = MSPShufOptions()
        var operands: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                operands.append(contentsOf: arguments.dropFirst(index + 1))
                break
            }
            if argument == "-e" || argument == "--echo" {
                options.echo = true
                index += 1
                continue
            }
            if argument == "-r" || argument == "--repeat" {
                options.repeatOutput = true
                index += 1
                continue
            }
            if argument == "-z" || argument == "--zero-terminated" {
                options.delimiter = 0
                index += 1
                continue
            }
            if argument == "-n" || argument == "-i" || argument == "-o" {
                guard index + 1 < arguments.count else {
                    throw MSPCommandFailure(result: .failure(
                        exitCode: 1,
                        stderr: "shuf: option requires an argument -- '\(argument.dropFirst())'\nTry 'shuf --help' for more information.\n"
                    ))
                }
                try assignValueOption(String(argument.dropFirst()), value: arguments[index + 1], options: &options)
                index += 2
                continue
            }
            if argument.hasPrefix("-n"), argument.count > 2 {
                try assignValueOption("n", value: String(argument.dropFirst(2)), options: &options)
                index += 1
                continue
            }
            if argument.hasPrefix("-i"), argument.count > 2 {
                try assignValueOption("i", value: String(argument.dropFirst(2)), options: &options)
                index += 1
                continue
            }
            if argument.hasPrefix("-o"), argument.count > 2 {
                try assignValueOption("o", value: String(argument.dropFirst(2)), options: &options)
                index += 1
                continue
            }
            if argument.hasPrefix("--random-source=") {
                options.randomSource = String(argument.dropFirst("--random-source=".count))
                index += 1
                continue
            }
            if argument == "--random-source" {
                guard index + 1 < arguments.count else {
                    throw MSPCommandFailure(result: .failure(
                        exitCode: 1,
                        stderr: "shuf: option '--random-source' requires an argument\nTry 'shuf --help' for more information.\n"
                    ))
                }
                options.randomSource = arguments[index + 1]
                index += 2
                continue
            }
            if argument.hasPrefix("--head-count=") {
                try assignValueOption("n", value: String(argument.dropFirst("--head-count=".count)), options: &options)
                index += 1
                continue
            }
            if argument == "--head-count" {
                guard index + 1 < arguments.count else {
                    throw MSPCommandFailure(result: .failure(
                        exitCode: 1,
                        stderr: "shuf: option '--head-count' requires an argument\nTry 'shuf --help' for more information.\n"
                    ))
                }
                try assignValueOption("n", value: arguments[index + 1], options: &options)
                index += 2
                continue
            }
            if argument.hasPrefix("--input-range=") {
                try assignValueOption("i", value: String(argument.dropFirst("--input-range=".count)), options: &options)
                index += 1
                continue
            }
            if argument == "--input-range" {
                guard index + 1 < arguments.count else {
                    throw MSPCommandFailure(result: .failure(
                        exitCode: 1,
                        stderr: "shuf: option '--input-range' requires an argument\nTry 'shuf --help' for more information.\n"
                    ))
                }
                try assignValueOption("i", value: arguments[index + 1], options: &options)
                index += 2
                continue
            }
            if argument.hasPrefix("--output=") {
                options.outputPath = String(argument.dropFirst("--output=".count))
                index += 1
                continue
            }
            if argument == "--output" {
                guard index + 1 < arguments.count else {
                    throw MSPCommandFailure(result: .failure(
                        exitCode: 1,
                        stderr: "shuf: option '--output' requires an argument\nTry 'shuf --help' for more information.\n"
                    ))
                }
                options.outputPath = arguments[index + 1]
                index += 2
                continue
            }
            if argument.hasPrefix("-"), argument != "-" {
                let invalid = argument.dropFirst().first ?? "?"
                throw MSPCommandFailure(result: .failure(
                    exitCode: 1,
                    stderr: "shuf: invalid option -- '\(invalid)'\nTry 'shuf --help' for more information.\n"
                ))
            }
            operands.append(argument)
            index += 1
        }
        options.operands = operands
        return options
    }

    private func assignValueOption(_ option: String, value: String, options: inout MSPShufOptions) throws {
        switch option {
        case "n":
            guard let count = Int(value), count >= 0 else {
                throw MSPCommandFailure(result: .failure(
                    exitCode: 1,
                    stderr: "shuf: invalid line count: \(MSPPOSIXCommandSupport.gnuQuote(value))\n"
                ))
            }
            options.headCount = count
        case "i":
            guard let range = MSPShufRange(value) else {
                throw MSPCommandFailure(result: .failure(
                    exitCode: 1,
                    stderr: "shuf: invalid input range: \(MSPPOSIXCommandSupport.gnuQuote(value))\n"
                ))
            }
            options.inputRange = range
        case "o":
            options.outputPath = value
        default:
            break
        }
    }

    private func makeRandomSource(
        _ path: String?,
        fileSystem: (any MSPWorkspaceFileSystem)?,
        context: MSPCommandContext
    ) throws -> MSPGNUShufRandom {
        guard let path else {
            var bytes = Data()
            for _ in 0..<256 {
                bytes.append(UInt8.random(in: UInt8.min...UInt8.max))
            }
            return MSPGNUShufRandom(bytes: bytes, repeatsWhenExhausted: true)
        }
        guard let fileSystem else {
            throw MSPCommandFailure(result: .failure(exitCode: 1, stderr: "shuf: workspace is required\n"))
        }
        do {
            let data = try fileSystem.readFile(path, from: context.currentDirectory)
            guard !data.isEmpty else {
                throw MSPCommandFailure(result: .failure(
                    exitCode: 1,
                    stderr: "shuf: \(path): end of file\n"
                ))
            }
            return MSPGNUShufRandom(bytes: data, repeatsWhenExhausted: false)
        } catch {
            if let failure = error as? MSPCommandFailure {
                throw failure
            }
            throw MSPCommandFailure(result: .failure(
                exitCode: 1,
                stderr: "shuf: \(path): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n"
            ))
        }
    }

    private func generateOutput(
        options: MSPShufOptions,
        context: MSPCommandContext,
        fileSystem: (any MSPWorkspaceFileSystem)?,
        random: inout MSPGNUShufRandom
    ) throws -> Data {
        if options.headCount == 0 {
            return Data()
        }
        if options.echo, options.inputRange != nil {
            throw MSPCommandFailure(result: .failure(
                exitCode: 1,
                stderr: "shuf: cannot combine -e and -i options\nTry 'shuf --help' for more information.\n"
            ))
        }

        if let inputRange = options.inputRange {
            let values = Array(inputRange.lower...inputRange.upper).map { Data(String($0).utf8) }
            return permutedOutput(records: values, delimiter: options.delimiter, options: options, random: &random)
        }

        let records: [Data]
        let stdinSizedLikePipe: Bool
        if options.echo {
            records = options.operands.map { Data($0.utf8) }
            stdinSizedLikePipe = false
        } else if let inputPath = options.operands.first, inputPath != "-" {
            guard let fileSystem else {
                throw MSPCommandFailure(result: .failure(exitCode: 1, stderr: "shuf: workspace is required\n"))
            }
            do {
                let data = try fileSystem.readFile(inputPath, from: context.currentDirectory)
                records = recordsFromShufInput(data, delimiter: options.delimiter)
                stdinSizedLikePipe = false
            } catch {
                throw MSPShufReadError(path: inputPath, underlying: error)
            }
        } else {
            records = recordsFromShufInput(context.standardInput, delimiter: options.delimiter)
            stdinSizedLikePipe = true
        }

        if options.repeatOutput {
            let count = options.headCount ?? records.count
            guard !records.isEmpty || count == 0 else {
                throw MSPCommandFailure(result: .failure(exitCode: 1, stderr: "shuf: no lines to repeat\n"))
            }
            var output = Data()
            for _ in 0..<count {
                let chosen = Int(random.choose(UInt64(records.count)))
                output.append(records[chosen])
                output.append(options.delimiter)
            }
            return output
        }

        if stdinSizedLikePipe,
           let headCount = options.headCount,
           headCount < records.count {
            let reservoir = reservoirSample(records: records, count: headCount, random: &random)
            return permutedOutput(records: reservoir, delimiter: options.delimiter, options: MSPShufOptions(), random: &random)
        }

        return permutedOutput(records: records, delimiter: options.delimiter, options: options, random: &random)
    }

    private func permutedOutput(
        records: [Data],
        delimiter: UInt8,
        options: MSPShufOptions,
        random: inout MSPGNUShufRandom
    ) -> Data {
        let requested = options.headCount ?? records.count
        let count = min(requested, records.count)
        let permutation = random.permutation(head: count, total: records.count)
        var output = Data()
        for index in permutation {
            output.append(records[index])
            output.append(delimiter)
        }
        return output
    }

    private func reservoirSample(records: [Data], count: Int, random: inout MSPGNUShufRandom) -> [Data] {
        guard records.count > count else {
            return records
        }
        var reservoir = Array(records.prefix(count))
        var lineCount = count
        for record in records.dropFirst(count) {
            let chosen = Int(random.choose(UInt64(lineCount + 1)))
            if chosen < count {
                reservoir[chosen] = record
            }
            lineCount += 1
        }
        _ = random.choose(UInt64(lineCount + 1))
        return reservoir
    }
}

private struct MSPShufOptions {
    var echo = false
    var repeatOutput = false
    var inputRange: MSPShufRange?
    var headCount: Int?
    var outputPath: String?
    var randomSource: String?
    var delimiter: UInt8 = 0x0A
    var operands: [String] = []
}

private struct MSPShufRange {
    var lower: Int
    var upper: Int

    init?(_ rawValue: String) {
        let parts = rawValue.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let lower = Int(parts[0]),
              let upper = Int(parts[1]),
              lower <= upper else {
            return nil
        }
        self.lower = lower
        self.upper = upper
    }
}

private struct MSPShufReadError: Error {
    var path: String
    var underlying: Error
}

private func recordsFromShufInput(_ data: Data, delimiter: UInt8) -> [Data] {
    guard !data.isEmpty else {
        return []
    }
    var records: [Data] = []
    var start = data.startIndex
    for index in data.indices where data[index] == delimiter {
        records.append(data.subdata(in: start..<index))
        start = index + 1
    }
    if start < data.endIndex {
        records.append(data.subdata(in: start..<data.endIndex))
    }
    return records
}

private struct MSPGNUShufRandom {
    var bytes: [UInt8]
    var repeatsWhenExhausted: Bool
    var offset = 0
    var randnum: UInt64 = 0
    var randmax: UInt64 = 0

    init(bytes: Data, repeatsWhenExhausted: Bool = false) {
        self.bytes = Array(bytes)
        self.repeatsWhenExhausted = repeatsWhenExhausted
    }

    mutating func choose(_ choices: UInt64) -> UInt64 {
        guard choices > 0 else {
            return 0
        }
        return genmax(choices - 1)
    }

    mutating func permutation(head: Int, total: Int) -> [Int] {
        guard head > 0 else {
            return []
        }
        if head == 1 {
            return [Int(choose(UInt64(total)))]
        }
        var values = Array(0..<total)
        for index in 0..<head {
            let chosen = index + Int(choose(UInt64(total - index)))
            values.swapAt(index, chosen)
        }
        return Array(values.prefix(head))
    }

    private mutating func genmax(_ genmax: UInt64) -> UInt64 {
        let choices = genmax + 1
        while true {
            if randmax < genmax {
                var bytesNeeded = 0
                var rmax = randmax
                repeat {
                    rmax = (rmax << 8) + 255
                    bytesNeeded += 1
                } while rmax < genmax

                let randomBytes = readBytes(bytesNeeded)
                var index = 0
                repeat {
                    randnum = (randnum << 8) + UInt64(randomBytes[index])
                    randmax = (randmax << 8) + 255
                    index += 1
                } while randmax < genmax
            }

            if randmax == genmax {
                let value = randnum
                randnum = 0
                randmax = 0
                return value
            }

            let excessChoices = randmax - genmax
            let unusableChoices = excessChoices % choices
            let lastUsableChoice = randmax - unusableChoices
            let reducedRandnum = randnum % choices
            if randnum <= lastUsableChoice {
                randnum /= choices
                randmax = excessChoices / choices
                return reducedRandnum
            }
            randnum = reducedRandnum
            randmax = unusableChoices - 1
        }
    }

    private mutating func readBytes(_ count: Int) -> [UInt8] {
        var output: [UInt8] = []
        for _ in 0..<count {
            if offset < bytes.count {
                output.append(bytes[offset])
                offset += 1
            } else if repeatsWhenExhausted, !bytes.isEmpty {
                offset = 1
                output.append(bytes[0])
            } else {
                output.append(0)
            }
        }
        return output
    }
}

private let mspShufUsageText = """
Usage: shuf [OPTION]... [FILE]
  or:  shuf -e [OPTION]... [ARG]...
  or:  shuf -i LO-HI [OPTION]...
Write a random permutation of the input lines to standard output.

  -e, --echo                treat each ARG as an input line
  -i, --input-range=LO-HI   treat each number LO through HI as an input line
  -n, --head-count=COUNT    output at most COUNT lines
  -o, --output=FILE         write result to FILE instead of standard output
      --random-source=FILE  get random bytes from FILE
  -r, --repeat              output lines can be repeated
  -z, --zero-terminated     line delimiter is NUL, not newline
      --help        display this help and exit
      --version     output version information and exit

"""
