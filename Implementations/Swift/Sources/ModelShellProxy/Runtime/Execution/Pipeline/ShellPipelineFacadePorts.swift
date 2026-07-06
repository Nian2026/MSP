import MSPCore
import MSPShell

extension ModelShellProxy {
    func pipelineRuntimePorts() -> ShellRuntimePipelinePorts {
        ShellRuntimePipelinePorts(
            singleCommandPorts: singleCommandRuntimePorts(),
            makeExpansionContext: { [self] requiresPathnameCandidates, lastExitCode in
                try await shellExpansionContext(
                    lastExitCode: lastExitCode,
                    requiresPathnameCandidates: requiresPathnameCandidates
                )
            },
            runCommandSubstitution: { [self] commandLine, standardInput, standardInputClosed, standardInputOverridesFileDescriptor, lastExitCode in
                await runCommandSubstitution(
                    commandLine,
                    standardInput: standardInput,
                    standardInputClosed: standardInputClosed,
                    standardInputOverridesFileDescriptor: standardInputOverridesFileDescriptor,
                    lastExitCode: lastExitCode
                )
            },
            resolveProcessSubstitution: { [self] request, standardInput, standardInputClosed, standardInputOverridesFileDescriptor, lastExitCode in
                try await resolvePipelineProcessSubstitution(
                    request,
                    standardInput: standardInput,
                    standardInputClosed: standardInputClosed,
                    standardInputOverridesFileDescriptor: standardInputOverridesFileDescriptor,
                    lastExitCode: lastExitCode
                )
            },
            cleanupProcessSubstitutions: { [self] startIndex in
                cleanupPipelineProcessSubstitutions(from: startIndex)
            },
            expansionFailureResult: { [self] error in
                shellExpansionFailureResult(error)
            },
            redirectionFailureResult: { [self] result, sourceLineNumber in
                shellRedirectionFailureResult(result, sourceLineNumber: sourceLineNumber)
            },
            applyRedirections: { [self] redirections, standardInput, standardInputClosed, standardInputOverridesFileDescriptor, currentDirectory, stdoutBindingOverride, stderrBindingOverride in
                try applyPipelineRedirections(
                    redirections,
                    standardInput: standardInput,
                    standardInputClosed: standardInputClosed,
                    standardInputOverridesFileDescriptor: standardInputOverridesFileDescriptor,
                    currentDirectory: currentDirectory,
                    stdoutBindingOverride: stdoutBindingOverride,
                    stderrBindingOverride: stderrBindingOverride
                )
            },
            fileOutputStream: { [self] sink in
                pipelineFileOutputStream(for: sink)
            },
            makeStreamingCommandContext: { [self] stage, standardInputStream, stdoutStream, stderrStream in
                var commandContextSeed = stage.commandContextSeed
                commandContextSeed.environment = exportedEnvironment(
                    from: stage.commandContextSeed.environment,
                    applying: stage.assignments
                )
                return commandContextSeed.makeCommandContext(
                    standardInput: stage.routing.standardInput,
                    standardInputClosed: stage.routing.standardInputClosed,
                    standardInputStream: standardInputStream,
                    standardOutputStream: stdoutStream,
                    standardErrorStream: stderrStream,
                    availableCommandNames: availableCommandNames(),
                    commandLookupPaths: availableCommandLookupPaths(),
                    subcommandRunner: makeSubcommandRunner(),
                    commandLineRunner: makeCommandLineRunner()
                )
            },
            emitRedirectionOutput: { [self] data, binding, visibleStdout, visibleStderr, writtenFilePaths in
                try emitPipelineRedirectionOutput(
                    data,
                    to: binding,
                    visibleStdout: &visibleStdout,
                    visibleStderr: &visibleStderr,
                    writtenFilePaths: &writtenFilePaths
                )
            },
            finalizeProcessSubstitutions: { [self] startIndex, result in
                try await appendScopedOutputProcessSubstitutions(
                    from: startIndex,
                    to: result
                )
            },
            recordAudit: { [self] parsed, fullCommandLine, result, startedAt in
                await recordAudit(
                    commandLine: parsedCommandsAuditLine(
                        parsed: parsed,
                        fullCommandLine: fullCommandLine
                    ),
                    parsed: parsed,
                    result: result,
                    startedAt: startedAt
                )
            },
            applyCommandStateChange: { [self] stateChange in
                applyStateChange(stateChange)
            },
            emitStreamProbe: { [self] event, fields in
                emitStreamProbe(event, fields: fields)
            }
        )
    }
}
