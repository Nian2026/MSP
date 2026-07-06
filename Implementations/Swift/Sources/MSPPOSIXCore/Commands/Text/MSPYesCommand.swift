import Foundation
import MSPCore

public struct MSPYesCommand: MSPStreamingCommand {
    public let name = "yes"
    public let summary: String? = "Repeatedly write a string to standard output."

    private let maxGeneratedBytes = 64 * 1024
    private let streamingChunkBytes = 16 * 1024

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let standardOption = MSPPOSIXCommandSupport.gnuStandardOptionResult(
            command: name,
            arguments: invocation.arguments,
            helpText: Self.helpText,
            versionText: Self.versionText
        ) {
            return standardOption
        }
        let line = invocation.arguments.isEmpty ? "y" : invocation.arguments.joined(separator: " ")
        let record = line + "\n"
        guard !record.isEmpty else {
            return .success()
        }

        var output = ""
        output.reserveCapacity(maxGeneratedBytes + record.count)
        while output.utf8.count < maxGeneratedBytes {
            output += record
        }
        return .success(stdout: output)
    }

    public func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let standardOption = MSPPOSIXCommandSupport.gnuStandardOptionResult(
            command: name,
            arguments: invocation.arguments,
            helpText: Self.helpText,
            versionText: Self.versionText
        ) {
            return standardOption
        }
        guard let standardOutput = context.standardOutputStream else {
            return try await run(invocation: invocation, context: context)
        }
        let line = invocation.arguments.isEmpty ? "y" : invocation.arguments.joined(separator: " ")
        let record = Data((line + "\n").utf8)
        guard !record.isEmpty else {
            return .success()
        }
        let outputUnit = standardOutput is MSPAsyncBytePipe
            ? repeatedChunk(record: record, minimumBytes: streamingChunkBytes)
            : record
        do {
            while !Task.isCancelled {
                try await standardOutput.write(outputUnit)
            }
        } catch MSPCommandStreamError.brokenPipe {
            return .success()
        }
        return .success()
    }

    private func repeatedChunk(record: Data, minimumBytes: Int) -> Data {
        guard record.count < minimumBytes else {
            return record
        }
        var chunk = Data()
        chunk.reserveCapacity(minimumBytes + record.count)
        while chunk.count < minimumBytes {
            chunk.append(record)
        }
        return chunk
    }

    private static let helpText = """
    Usage: yes [STRING]...
      or:  yes OPTION
    Repeatedly output a line with all specified STRING(s), or 'y'.

          --help        display this help and exit
          --version     output version information and exit

    GNU coreutils online help: <https://www.gnu.org/software/coreutils/>
    Report any translation bugs to <https://translationproject.org/team/>
    Full documentation <https://www.gnu.org/software/coreutils/yes>
    or available locally via: info '(coreutils) yes invocation'
    """

    private static let versionText = """
    yes (GNU coreutils) 9.1
    Copyright (C) 2022 Free Software Foundation, Inc.
    License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.
    This is free software: you are free to change and redistribute it.
    There is NO WARRANTY, to the extent permitted by law.

    Written by David MacKenzie.
    """
}
