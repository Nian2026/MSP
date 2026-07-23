import Foundation
import MSPCore

public struct MSPRgCommand: MSPStreamingCommand {
    public let name = "rg"
    public let summary: String? = "Recursively search workspace text."

    public init() {}

    public func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let output = RgBufferedOutputWriter()
        return try await run(invocation: invocation, context: context, output: output)
    }

    public func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        guard let standardOutput = context.standardOutputStream else {
            return try await run(invocation: invocation, context: context)
        }
        let output = RgStreamingOutputWriter(
            standardOutput: standardOutput,
            standardError: context.standardErrorStream ?? MSPBlackHoleOutputStream()
        )
        return try await run(invocation: invocation, context: context, output: output)
    }

    private func run(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext,
        output: any RgOutputWriter
    ) async throws -> MSPCommandResult {
        if invocation.arguments.contains("--version") {
            try await output.appendStdout("ripgrep 13.0.0\n")
            return .success(stdoutData: await output.stdoutData, stderr: await output.stderr)
        }
        if invocation.arguments.contains("-h") || invocation.arguments.contains("--help") {
            try await output.appendStdout(mspRgUsageText)
            return .success(stdoutData: await output.stdoutData, stderr: await output.stderr)
        }

        let query = try RgQuery(arguments: invocation.arguments)
        guard query.filesOnly || !query.patterns.isEmpty else {
            throw MSPCommandFailure.usage("rg: missing pattern\n")
        }

        let state = RgRunState()
        if shouldSearchRgStandardInput(query: query, context: context) {
            do {
                let matcher = try RgMatcher(
                    patterns: query.patterns,
                    fixedStrings: query.fixedStrings,
                    ignoreCase: query.ignoreCase,
                    wordRegexp: query.wordRegexp,
                    lineRegexp: query.lineRegexp
                )
                try await searchRgStandardInput(
                    try await rgStandardInputData(context),
                    query: query,
                    matcher: matcher,
                    output: output,
                    state: state
                )
                return MSPCommandResult(
                    stdoutData: await output.stdoutData,
                    stderr: await output.stderr,
                    exitCode: state.anyMatched ? 0 : 1
                )
            } catch MSPCommandStreamError.brokenPipe {
                return .success(stdoutData: await output.stdoutData, stderr: await output.stderr)
            }
        }

        let fileSystem = try MSPPOSIXCommandSupport.workspaceFileSystem(from: context, command: name)
        let roots = try await resolveRgRoots(
            query: query,
            fileSystem: fileSystem,
            context: context,
            output: output,
            state: state
        )

        do {
            if query.filesOnly {
                for root in roots.items {
                    _ = try await visitRgFiles(
                        root.info,
                        displayPath: root.displayPath,
                        fileSystem: fileSystem,
                        query: query,
                        output: output,
                        state: state
                    ) { candidate in
                        state.anyMatched = true
                        try await output.appendStdoutLine(candidate.displayPath)
                        return true
                    }
                }
                return MSPCommandResult(
                    stdoutData: await output.stdoutData,
                    stderr: await output.stderr,
                    exitCode: state.hadDiagnostics ? 2 : (state.anyMatched ? 0 : 1)
                )
            }

            let matcher = try RgMatcher(
                patterns: query.patterns,
                fixedStrings: query.fixedStrings,
                ignoreCase: query.ignoreCase,
                wordRegexp: query.wordRegexp,
                lineRegexp: query.lineRegexp
            )
            let prefixPath = query.forceWithFilename
                || roots.containsDirectory
                || roots.regularFileCount > 1

            for root in roots.items {
                _ = try await visitRgFiles(
                    root.info,
                    displayPath: root.displayPath,
                    fileSystem: fileSystem,
                    query: query,
                    output: output,
                    state: state,
                    reportBinaryMatches: root.info.type == .regularFile
                ) { candidate in
                    try await searchRgFile(
                        candidate,
                        fileSystem: fileSystem,
                        query: query,
                        matcher: matcher,
                        prefixPath: prefixPath,
                        output: output,
                        state: state
                    )
                    return true
                }
            }

            if state.hadDiagnostics {
                return MSPCommandResult(
                    stdoutData: await output.stdoutData,
                    stderr: await output.stderr,
                    exitCode: 2
                )
            }
            return MSPCommandResult(
                stdoutData: await output.stdoutData,
                stderr: await output.stderr,
                exitCode: state.anyMatched ? 0 : 1
            )
        } catch MSPCommandStreamError.brokenPipe {
            return .success(stdoutData: await output.stdoutData, stderr: await output.stderr)
        }
    }
}

private func shouldSearchRgStandardInput(
    query: RgQuery,
    context: MSPCommandContext
) -> Bool {
    !query.filesOnly
        && query.paths.isEmpty
        && (context.standardInputOverridesFileDescriptor || !context.standardInput.isEmpty)
}

private func rgStandardInputData(_ context: MSPCommandContext) async throws -> Data {
    guard let stream = context.standardInputStream else {
        return context.standardInput
    }
    var data = Data()
    while let chunk = try await stream.read(maxBytes: 32 * 1024) {
        data.append(chunk)
    }
    return data
}
