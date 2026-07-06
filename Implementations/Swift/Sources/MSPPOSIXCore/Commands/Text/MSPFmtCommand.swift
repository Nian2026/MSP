import Foundation
import MSPCore

public struct MSPFmtCommand: MSPStreamingCommand {
    public let name = "fmt"
    public let summary: String? = "Reformat simple text paragraphs."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let standard = MSPPOSIXCommandSupport.gnuStandardOptionResult(
            command: name,
            arguments: invocation.arguments,
            helpText: MSPFmtConfiguration.helpText,
            versionText: MSPPOSIXCommandSupport.gnuCoreutilsVersionText(command: name)
        ) {
            return standard
        }
        let configuration = try MSPFmtConfiguration(arguments: invocation.arguments)
        let input = try await mspTextLayoutData(
            operands: configuration.operands,
            context: context,
            command: name,
            fileReadDiagnostic: { displayPath, reason in
                "fmt: cannot open '\(displayPath)' for reading: \(reason)"
            }
        )
        var stdout = Data()
        for item in input.inputs {
            stdout.append(mspFmtRender(data: item.data, configuration: configuration))
        }
        return MSPCommandResult(
            stdoutData: stdout,
            stderr: input.diagnostics.isEmpty ? "" : input.diagnostics.joined(separator: "\n") + "\n",
            exitCode: input.exitCode
        )
    }

    public func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let standard = MSPPOSIXCommandSupport.gnuStandardOptionResult(
            command: name,
            arguments: invocation.arguments,
            helpText: MSPFmtConfiguration.helpText,
            versionText: MSPPOSIXCommandSupport.gnuCoreutilsVersionText(command: name)
        ) {
            return standard
        }
        let configuration = try MSPFmtConfiguration(arguments: invocation.arguments)
        guard configuration.operands.isEmpty else {
            return try await run(invocation: invocation, context: context)
        }
        return try await mspTextLayoutRunStreamingFromStandardInput(
            invocation: invocation,
            context: context,
            command: run(invocation:context:)
        )
    }
}
