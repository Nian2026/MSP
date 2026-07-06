import Foundation
import MSPCore

public struct MSPTrCommand: MSPStreamingCommand {
    public let name = "tr"
    public let summary: String? = "Translate, delete, or squeeze characters."

    private let spec = MSPPOSIXCommandSpec(
        name: "tr",
        allowedShortOptions: ["c", "C", "d", "s", "t"],
        allowedLongOptions: ["complement", "delete", "squeeze-repeats", "truncate-set1"]
    )

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

        let parsed = try spec.parse(invocation.arguments)
        let configuration = try mspTrParseConfiguration(parsed)
        if var byteProcessor = TrByteProcessor(configuration: configuration) {
            return .success(stdoutData: byteProcessor.process(context.standardInput))
        }

        let input = String(decoding: context.standardInput, as: UTF8.self)
        var scalarProcessor = TrScalarProcessor(configuration: configuration)
        return .success(stdout: scalarProcessor.process(input))
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

        guard let standardInput = context.standardInputStream,
              let standardOutput = context.standardOutputStream
        else {
            return try await run(invocation: invocation, context: context)
        }

        let parsed = try spec.parse(invocation.arguments)
        let configuration = try mspTrParseConfiguration(parsed)
        do {
            if var byteProcessor = TrByteProcessor(configuration: configuration) {
                try await streamTrByteOutput(
                    standardInput: standardInput,
                    standardOutput: standardOutput,
                    processor: &byteProcessor
                )
            } else {
                var scalarProcessor = TrScalarProcessor(configuration: configuration)
                try await streamTrScalarOutput(
                    standardInput: standardInput,
                    standardOutput: standardOutput,
                    processor: &scalarProcessor
                )
            }
        } catch MSPCommandStreamError.brokenPipe {
            return .success()
        }
        return .success()
    }

    private static let helpText = """
    Usage: tr [OPTION]... STRING1 [STRING2]
    Translate, squeeze, and/or delete characters from standard input.

      -c, -C, --complement    use the complement of STRING1
      -d, --delete            delete characters in STRING1
      -s, --squeeze-repeats   replace repeated characters with one occurrence
      -t, --truncate-set1     first truncate STRING1 to length of STRING2
          --help              display this help and exit
          --version           output version information and exit
    """
}
