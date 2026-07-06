import Foundation
import MSPCore

public struct MSPOdCommand: MSPCommand {
    public let name = "od"
    public let summary: String? = "Dump files in octal and other formats."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let standardResult = MSPOdConfiguration.standardResult(for: invocation.arguments) {
            return standardResult
        }

        let configuration = try MSPOdConfiguration.parse(invocation.arguments)
        let visibleInput = try await MSPOdInput.load(
            operands: configuration.operands,
            context: context,
            command: name,
            skipBytes: configuration.skipBytes,
            byteLimit: configuration.byteLimit
        )

        guard visibleInput.exitCode == 0 || !visibleInput.data.isEmpty else {
            return MSPCommandResult(
                stderr: visibleInput.diagnostics,
                exitCode: visibleInput.exitCode
            )
        }

        let stdout = MSPOdRenderer(configuration: configuration).render(data: visibleInput.data)
        return MSPCommandResult(
            stdout: stdout,
            stderr: visibleInput.diagnostics,
            exitCode: visibleInput.exitCode
        )
    }
}
