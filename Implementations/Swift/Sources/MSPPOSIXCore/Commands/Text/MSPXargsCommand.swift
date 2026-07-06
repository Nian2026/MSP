import Foundation
import MSPCore

public struct MSPXargsCommand: MSPStreamingCommand {
    public let name = "xargs"
    public let summary: String? = "Build and execute command lines from standard input."

    private let spec = MSPPOSIXCommandSpec(
        name: "xargs",
        allowedShortOptions: ["0", "r", "t", "x"],
        allowedLongOptions: ["null", "no-run-if-empty", "verbose", "exit", "help", "version"],
        shortOptionsRequiringValue: ["a", "d", "E", "I", "L", "n", "P", "s"],
        longOptionsRequiringValue: ["arg-file", "delimiter", "eof", "replace", "max-lines", "max-args", "max-procs", "max-chars"],
        shortOptionsWithOptionalValue: ["e", "i", "l"]
    )

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") {
            return .success(stdout: mspXargsUsageText)
        }
        if invocation.arguments.contains("--version") {
            return .success(stdout: "xargs (GNU findutils) 4.9.0\n")
        }
        let parsed = try spec.parse(invocation.arguments, stopAtFirstOperand: true)
        var delimiter: Character?
        var nullDelimited = false
        var replacement: String?
        var maxArgs: Int?
        var maxLines: Int?
        var maxCharacters = 128 * 1024
        var noRunIfEmpty = false
        var verbose = false
        var argFile: String?
        var eofMarker: String?

        for option in parsed.options {
            switch option.name {
            case .short("0"), .long("null"):
                nullDelimited = true
                delimiter = "\0"
            case .short("d"), .long("delimiter"):
                delimiter = try mspPOSIXXargsDelimiter(option.value ?? "")
                nullDelimited = delimiter == "\0"
            case .short("E"), .short("e"), .long("eof"):
                eofMarker = option.value ?? ""
            case .short("I"), .short("i"), .long("replace"):
                replacement = (option.value?.isEmpty ?? true) ? "{}" : (option.value ?? "{}")
            case .short("l"):
                maxLines = try option.value.map {
                    try mspPOSIXXargsPositiveInteger($0, option: MSPPOSIXOptionParser.optionDisplayName(option))
                } ?? 1
            case .short("L"), .long("max-lines"):
                maxLines = try mspPOSIXXargsPositiveInteger(option.value ?? "", option: MSPPOSIXOptionParser.optionDisplayName(option))
            case .short("n"), .long("max-args"):
                maxArgs = try mspPOSIXXargsPositiveInteger(option.value ?? "", option: MSPPOSIXOptionParser.optionDisplayName(option))
            case .short("s"), .long("max-chars"):
                maxCharacters = try mspPOSIXXargsPositiveInteger(option.value ?? "", option: MSPPOSIXOptionParser.optionDisplayName(option))
            case .short("P"), .long("max-procs"):
                _ = try mspPOSIXXargsNonNegativeInteger(option.value ?? "", option: MSPPOSIXOptionParser.optionDisplayName(option))
            case .short("a"), .long("arg-file"):
                argFile = option.value
            case .short("r"), .long("no-run-if-empty"):
                noRunIfEmpty = true
            case .short("t"), .long("verbose"):
                verbose = true
            case .short("x"), .long("exit"):
                continue
            default:
                continue
            }
        }

        var commandWords = parsed.operands
        if commandWords.isEmpty {
            commandWords = ["echo"]
        }
        let inputText: String
        if let argFile {
            let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
            do {
                inputText = String(decoding: try fileSystem.readFile(argFile, from: context.currentDirectory), as: UTF8.self)
            } catch {
                return .failure(exitCode: 1, stderr: "xargs: \(argFile): \(MSPPOSIXCommandSupport.diagnosticReason(from: error))\n")
            }
        } else {
            inputText = String(decoding: context.standardInput, as: UTF8.self)
        }
        let batches: [[String]]
        if let maxLines, replacement == nil, delimiter == nil, !nullDelimited {
            let logicalLines = try mspPOSIXXargsLogicalLines(from: inputText, eofMarker: eofMarker)
            guard !logicalLines.isEmpty else {
                if noRunIfEmpty {
                    return .success()
                }
                return await runCommands(
                    [commandWords],
                    context: context,
                    verbose: verbose,
                    maxCharacters: maxCharacters,
                    clearsChildStandardInput: argFile == nil
                )
            }
            batches = try mspPOSIXXargsLineBatches(
                commandWords: commandWords,
                lines: logicalLines,
                maxLines: maxLines,
                maxArgs: maxArgs,
                maxCharacters: maxCharacters
            )
        } else {
            let values = try mspPOSIXXargsValues(
                from: inputText,
                delimiter: delimiter,
                nullDelimited: nullDelimited,
                lineDelimited: replacement != nil,
                eofMarker: eofMarker
            )
            guard !values.isEmpty else {
                if noRunIfEmpty || replacement != nil {
                    return .success()
                }
                return await runCommands(
                    [commandWords],
                    context: context,
                    verbose: verbose,
                    maxCharacters: maxCharacters,
                    clearsChildStandardInput: argFile == nil
                )
            }

            if let replacement {
                batches = values.map { value in
                    commandWords.map { $0.replacingOccurrences(of: replacement, with: value) }
                }
            } else {
                batches = try mspPOSIXXargsBatches(
                    commandWords: commandWords,
                    values: values,
                    maxArgs: maxArgs,
                    maxCharacters: maxCharacters
                )
            }
        }

        return await runCommands(
            batches,
            context: context,
            verbose: verbose,
            maxCharacters: maxCharacters,
            clearsChildStandardInput: argFile == nil
        )
    }

    public func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") {
            return .success(stdout: mspXargsUsageText)
        }
        if invocation.arguments.contains("--version") {
            return .success(stdout: "xargs (GNU findutils) 4.9.0\n")
        }
        let standardOutputBuffer: MSPCommandOutputBuffer?
        let standardOutput: any MSPCommandOutputStream
        if let stream = context.standardOutputStream {
            standardOutputBuffer = nil
            standardOutput = stream
        } else {
            let buffer = MSPCommandOutputBuffer()
            standardOutputBuffer = buffer
            standardOutput = buffer
        }

        let standardErrorBuffer: MSPCommandOutputBuffer?
        let standardError: any MSPCommandOutputStream
        if let stream = context.standardErrorStream {
            standardErrorBuffer = nil
            standardError = stream
        } else {
            let buffer = MSPCommandOutputBuffer()
            standardErrorBuffer = buffer
            standardError = buffer
        }

        let parsed = try spec.parse(invocation.arguments, stopAtFirstOperand: true)
        var options = MSPXargsStreamingOptions()
        for option in parsed.options {
            switch option.name {
            case .short("0"), .long("null"):
                options.nullDelimited = true
                options.delimiter = "\0"
            case .short("d"), .long("delimiter"):
                options.delimiter = try mspPOSIXXargsDelimiter(option.value ?? "")
                options.nullDelimited = options.delimiter == "\0"
            case .short("E"), .short("e"), .long("eof"):
                options.eofMarker = option.value ?? ""
            case .short("I"), .short("i"), .long("replace"):
                options.replacement = (option.value?.isEmpty ?? true) ? "{}" : (option.value ?? "{}")
            case .short("l"):
                options.maxLines = try option.value.map {
                    try mspPOSIXXargsPositiveInteger($0, option: MSPPOSIXOptionParser.optionDisplayName(option))
                } ?? 1
            case .short("L"), .long("max-lines"):
                options.maxLines = try mspPOSIXXargsPositiveInteger(option.value ?? "", option: MSPPOSIXOptionParser.optionDisplayName(option))
            case .short("n"), .long("max-args"):
                options.maxArgs = try mspPOSIXXargsPositiveInteger(option.value ?? "", option: MSPPOSIXOptionParser.optionDisplayName(option))
            case .short("s"), .long("max-chars"):
                options.maxCharacters = try mspPOSIXXargsPositiveInteger(option.value ?? "", option: MSPPOSIXOptionParser.optionDisplayName(option))
            case .short("P"), .long("max-procs"):
                _ = try mspPOSIXXargsNonNegativeInteger(option.value ?? "", option: MSPPOSIXOptionParser.optionDisplayName(option))
            case .short("a"), .long("arg-file"):
                options.argFile = option.value
                options.clearsChildStandardInput = false
            case .short("r"), .long("no-run-if-empty"):
                options.noRunIfEmpty = true
            case .short("t"), .long("verbose"):
                options.verbose = true
            case .short("x"), .long("exit"):
                continue
            default:
                continue
            }
        }
        options.commandWords = parsed.operands.isEmpty ? ["echo"] : parsed.operands

        let inputStream: any MSPCommandInputStream
        if let argFile = options.argFile {
            let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
            inputStream = MSPWorkspaceFileInputStream(
                fileSystem: fileSystem,
                path: argFile,
                currentDirectory: context.currentDirectory
            )
        } else {
            inputStream = context.standardInputStream ?? MSPDataInputStream(context.standardInput)
        }

        var processor = MSPXargsStreamingInputProcessor(options: options)
        var executor = MSPXargsStreamingExecutor(
            options: options,
            context: context,
            standardOutput: standardOutput,
            standardError: standardError
        )
        do {
            inputLoop: while let chunk = try await inputStream.read(maxBytes: 32 * 1024) {
                let records = try processor.append(chunk)
                for record in records {
                    try await executor.consume(record)
                    if executor.shouldStopConsumingInput {
                        await inputStream.closeRead()
                        break inputLoop
                    }
                }
                if processor.shouldStopConsumingInput {
                    await inputStream.closeRead()
                    break inputLoop
                }
            }
            if !executor.shouldStopConsumingInput {
                let records = try processor.finish()
                for record in records {
                    try await executor.consume(record)
                    if executor.shouldStopConsumingInput {
                        await inputStream.closeRead()
                        break
                    }
                }
            }
            return await mspPOSIXXargsFinalizeStreamingResult(
                try await executor.finish(),
                stdoutBuffer: standardOutputBuffer,
                stderrBuffer: standardErrorBuffer
            )
        } catch MSPCommandStreamError.brokenPipe {
            return await mspPOSIXXargsFinalizeStreamingResult(
                executor.result(),
                stdoutBuffer: standardOutputBuffer,
                stderrBuffer: standardErrorBuffer
            )
        }
    }

}

private func mspPOSIXXargsFinalizeStreamingResult(
    _ result: MSPCommandResult,
    stdoutBuffer: MSPCommandOutputBuffer?,
    stderrBuffer: MSPCommandOutputBuffer?
) async -> MSPCommandResult {
    var finalized = result
    if let stdoutBuffer {
        finalized.stdoutData = await stdoutBuffer.data()
    }
    if let stderrBuffer {
        finalized.stderrData = await stderrBuffer.data()
    }
    return finalized
}
