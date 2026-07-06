import Foundation
import MSPCore

public struct MSPWcCommand: MSPStreamingCommand {
    public let name = "wc"
    public let summary: String? = "Print newline, word, and byte counts."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let standard = MSPPOSIXCommandSupport.gnuStandardOptionResult(
            command: name,
            arguments: invocation.arguments,
            helpText: Self.helpText,
            versionText: MSPPOSIXCommandSupport.gnuCoreutilsVersionText(command: name)
        ) {
            return standard
        }
        let parsed = try Self.spec.parse(invocation.arguments)
        let selection = WcSelection(options: parsed.options)
        let files0From = parsed.options.last { $0.matches(long: "files0-from") }?.value
        if files0From != nil, !parsed.operands.isEmpty {
            return .failure(
                stderr: "wc: extra operand \(MSPPOSIXCommandSupport.gnuQuote(parsed.operands[0]))\nfile operands cannot be combined with --files0-from\nTry 'wc --help' for more information.\n"
            )
        }
        let operands: [String]
        do {
            operands = try files0From.map { try fileListOperands(from: $0, context: context) } ?? parsed.operands
        } catch let failure as MSPCommandFailure {
            return failure.result
        }
        let inputResult = try wcInputRows(
            operands: operands,
            context: context,
            readStandardInputWhenEmpty: files0From == nil
        )

        var rows = inputResult.rows

        if operands.count > 1 {
            rows.append(WcRow(counts: WcCounts.total(of: rows), label: "total"))
        }

        let width = wcCountColumnWidth(
            rows: rows,
            operandCount: operands.count,
            selection: selection
        )
        let stdout = rows
            .map { wcLine(row: $0, selection: selection, countColumnWidth: width) }
            .joined(separator: "\n")
        let stderrLines = inputResult.diagnostics
        let stderr = stderrLines.isEmpty ? "" : stderrLines.joined(separator: "\n") + "\n"
        return MSPCommandResult(
            stdout: stdout.isEmpty ? "" : stdout + "\n",
            stderr: stderr,
            exitCode: inputResult.exitCode
        )
    }

    public func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let standard = MSPPOSIXCommandSupport.gnuStandardOptionResult(
            command: name,
            arguments: invocation.arguments,
            helpText: Self.helpText,
            versionText: MSPPOSIXCommandSupport.gnuCoreutilsVersionText(command: name)
        ) {
            return standard
        }
        let parsed = try Self.spec.parse(invocation.arguments)
        guard parsed.operands.isEmpty,
              !parsed.options.contains(where: { $0.matches(long: "debug") }),
              !parsed.options.contains(where: { $0.matches(long: "files0-from") }),
              let standardInput = context.standardInputStream,
              let standardOutput = context.standardOutputStream
        else {
            return try await run(invocation: invocation, context: context)
        }

        let selection = WcSelection(options: parsed.options)
        var counter = WcStreamingCounter()
        do {
            while let chunk = try await standardInput.read(maxBytes: 32 * 1024) {
                counter.append(chunk)
            }
            counter.finish()
            let row = WcRow(counts: counter.counts, label: nil)
            let stdout = wcLine(
                row: row,
                selection: selection,
                countColumnWidth: wcCountColumnWidth(rows: [row], operandCount: 0, selection: selection)
            ) + "\n"
            try await standardOutput.write(Data(stdout.utf8))
        } catch MSPCommandStreamError.brokenPipe {
            return .success()
        }
        return .success()
    }
}
