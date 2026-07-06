import Foundation
import MSPCore

public struct MSPGrepCommand: MSPStreamingCommand {
    public let name = "grep"
    public let summary: String? = "Search text for matching lines."

    private let spec = GrepCommandMetadata.spec

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let standardOption = GrepCommandMetadata.standardOptionResult(arguments: invocation.arguments) {
            return standardOption
        }
        let parsed = try spec.parse(grepPreprocessDigitContextOptions(invocation.arguments))
        let options = try GrepOptions(parsed: parsed, context: context)
        guard options.hasPatternSource else {
            throw MSPCommandFailure.usage("grep: missing pattern\n")
        }
        let compiled = try options.compiledPatterns(command: name)
        if options.maxCount == 0, !options.filesWithoutMatches {
            return MSPCommandResult(exitCode: 1)
        }

        let alwaysPrefixPath = options.forceWithFilename
            || (!options.forceWithoutFilename && (options.recursive || options.paths.count > 1))
        let state = GrepRunState()
        state.diagnostics.append(contentsOf: options.warnings)
        state.suppressMessages = options.suppressMessages
        try await grepVisitSources(
            paths: options.paths,
            options: options,
            context: context,
            state: state
        ) { source in
            grepProcessSource(
                source,
                options: options,
                compiled: compiled,
                alwaysPrefixPath: alwaysPrefixPath,
                state: state
            )
            return !state.stopAll
        }
        if state.stopAll, options.quiet {
            return .success()
        }
        let separator = (options.nullData || (options.nullFileName && (options.filesWithMatches || options.filesWithoutMatches))) ? "\0" : "\n"
        return MSPCommandResult(
            stdout: state.rows.isEmpty ? "" : state.rows.joined(separator: separator) + separator,
            stderr: state.diagnostics.isEmpty ? "" : state.diagnostics.joined(separator: "\n") + "\n",
            exitCode: state.errorSeen ? 2 : (state.anyMatched ? 0 : 1)
        )
    }

    public func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        if let standardOption = GrepCommandMetadata.standardOptionResult(arguments: invocation.arguments) {
            return standardOption
        }
        let parsed = try spec.parse(grepPreprocessDigitContextOptions(invocation.arguments))
        let options = try GrepOptions(parsed: parsed, context: context)
        guard options.hasPatternSource else {
            throw MSPCommandFailure.usage("grep: missing pattern\n")
        }
        guard options.paths.isEmpty,
              !options.countOnly,
              !options.filesWithoutMatches,
              !options.nullData,
              !options.byteOffset,
              !options.hasContext,
              !options.standardInputConsumedByOptionFile,
              let standardInput = context.standardInputStream,
              let standardOutput = context.standardOutputStream
        else {
            return try await run(invocation: invocation, context: context)
        }
        let compiled = try options.compiledPatterns(command: name)
        do {
            var result = try await grepStreamStandardInput(
                options: options,
                compiled: compiled,
                standardInput: standardInput,
                standardOutput: standardOutput
            )
            if !options.warnings.isEmpty {
                result.stderr = options.warnings.joined(separator: "\n") + "\n"
            }
            return result
        } catch MSPCommandStreamError.brokenPipe {
            return .success()
        }
    }
}
