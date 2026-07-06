import Foundation
import MSPCore

public struct MSPSortCommand: MSPCommand {
    public let name = "sort"
    public let summary: String? = "Sort text records."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--help") {
            return .success(stdout: mspSortHelp())
        }
        if invocation.arguments.contains("--version") {
            return .success(stdout: "sort (GNU coreutils) 9.1\n")
        }
        let spec = MSPPOSIXCommandSpec(
            name: name,
            allowedShortOptions: ["b", "d", "f", "g", "h", "i", "M", "m", "n", "R", "r", "s", "u", "V", "z", "c", "C"],
            allowedLongOptions: [
                "debug",
                "ignore-leading-blanks",
                "dictionary-order",
                "ignore-case",
                "general-numeric-sort",
                "numeric-sort",
                "random-sort",
                "reverse",
                "human-numeric-sort",
                "ignore-nonprinting",
                "month-sort",
                "merge",
                "version-sort",
                "unique",
                "zero-terminated",
                "check",
                "stable",
                "help",
                "version"
            ],
            shortOptionsRequiringValue: ["t", "k", "o", "S", "T"],
            longOptionsRequiringValue: [
                "field-separator",
                "key",
                "output",
                "random-source",
                "sort",
                "files0-from",
                "buffer-size",
                "temporary-directory",
                "batch-size",
                "parallel"
            ],
            longOptionsWithOptionalValue: ["check"]
        )
        let parsed = try spec.parse(invocation.arguments)
        var options = try SortOptions(parsed)
        let operands = try sortInputOperands(
            commandLineOperands: parsed.operands,
            files0From: options.files0From,
            context: context
        )
        if options.random {
            options.randomSeed = try sortRandomSeed(options: options, context: context)
        }
        let inputResult = try await MSPPOSIXCommandSupport.inputData(
            operands: operands,
            context: context,
            command: name
        )

        if options.checkOnly {
            let failure = inputResult.inputs.lazy.compactMap { input in
                checkSorted(
                    mspPOSIXTextRecords(in: input.data, delimiter: options.zeroTerminated ? 0 : 0x0A),
                    label: input.label ?? "-",
                    options: options
                )
            }.first
            let stderr = inputResult.diagnostics + (failure.map { [$0] } ?? [])
            return MSPCommandResult(
                stderr: options.quietCheck ? "" : (stderr.isEmpty ? "" : stderr.joined(separator: "\n") + "\n"),
                exitCode: failure == nil ? inputResult.exitCode : 1
            )
        }

        var records = options.merge
            ? mergePresortedSortInputs(inputResult.inputs, options: options)
            : sortedSortInputs(inputResult.inputs, options: options)
        if options.unique {
            var uniqueRecords: [SortRecord] = []
            var previous: SortRecord?
            for record in records where previous.map({ !sortRecordsEquivalentForUnique($0.data, record.data, options: options) }) ?? true {
                uniqueRecords.append(record)
                previous = record
            }
            records = uniqueRecords
        }

        let output = mspPOSIXRecordsOutput(records.map(\.data), delimiter: options.zeroTerminated ? 0 : 0x0A)
        let debugStderr = options.debug ? "sort: text ordering performed using \(MSPPOSIXCommandSupport.gnuQuote("C.UTF-8")) sorting rules\n" : ""
        if let outputPath = options.outputPath {
            let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
            try fileSystem.writeFile(
                outputPath,
                data: output,
                from: context.currentDirectory,
                options: [.overwriteExisting, .createParentDirectories],
                creationMode: context.regularFileCreationMode
            )
            let stderr = debugStderr + (inputResult.diagnostics.isEmpty ? "" : inputResult.diagnostics.joined(separator: "\n") + "\n")
            return MSPCommandResult(stderr: stderr, exitCode: inputResult.exitCode)
        }

        let stdout = options.debug ? sortDebugOutput(records: records, options: options) : output
        let stderr = debugStderr + (inputResult.diagnostics.isEmpty ? "" : inputResult.diagnostics.joined(separator: "\n") + "\n")
        return MSPCommandResult(
            stdoutData: stdout,
            stderr: stderr,
            exitCode: inputResult.exitCode
        )
    }
}
