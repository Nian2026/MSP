import Foundation
import MSPCore

public struct MSPBase32Command: MSPCommand {
    public let name = "base32"
    public let summary: String? = "Base32 encode or decode data."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        try MSPBaseEncodingCommandRunner(command: name, fixedKind: .base32)
            .run(arguments: invocation.arguments, context: context)
    }
}

public struct MSPBasencCommand: MSPCommand {
    public let name = "basenc"
    public let summary: String? = "Encode or decode data with a selected base encoding."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        try MSPBaseEncodingCommandRunner(command: name, fixedKind: nil)
            .run(arguments: invocation.arguments, context: context)
    }
}
