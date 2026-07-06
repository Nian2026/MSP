import Foundation
import MSPCore
import MSPShell

extension ModelShellProxy {
    func singleCommandRuntimePorts() -> ShellRuntimeSingleCommandPorts {
        ShellRuntimeSingleCommandPorts(
            cleanupProcessSubstitutionTemporaryPaths: { [self] startIndex in
                cleanupSingleCommandProcessSubstitutionTemporaryPaths(from: startIndex)
            },
            makeExpansionContext: { [self] lastExitCode, requiresPathnameCandidates in
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
                try await resolveSingleCommandProcessSubstitution(
                    request,
                    standardInput: standardInput,
                    standardInputClosed: standardInputClosed,
                    standardInputOverridesFileDescriptor: standardInputOverridesFileDescriptor,
                    lastExitCode: lastExitCode
                )
            },
            expansionFailureResult: { [self] error in
                shellExpansionFailureResult(error)
            },
            recordAudit: { [self] commandLine, parsed, result, startedAt in
                await recordAudit(
                    commandLine: commandLine,
                    parsed: parsed,
                    result: result,
                    startedAt: startedAt
                )
            },
            parsedCommandsAuditLine: { [self] parsed, fullCommandLine in
                parsedCommandsAuditLine(parsed: parsed, fullCommandLine: fullCommandLine)
            },
            redirectionFailureResult: { [self] result, sourceLineNumber in
                shellRedirectionFailureResult(result, sourceLineNumber: sourceLineNumber)
            },
            commandLookupFailureResult: { [self] result, commandName, sourceLineNumber in
                shellCommandLookupFailureResult(
                    result,
                    commandName: commandName,
                    sourceLineNumber: sourceLineNumber
                )
            },
            applyRedirections: { [self] redirections, frame, currentDirectory in
                try applySingleCommandRedirections(
                    redirections,
                    standardInput: frame.standardInput,
                    standardInputClosed: frame.standardInputClosed,
                    standardInputOverridesFileDescriptor: frame.standardInputOverridesFileDescriptor,
                    currentDirectory: currentDirectory,
                    stdoutBindingOverride: frame.stdoutBindingOverride,
                    stderrBindingOverride: frame.stderrBindingOverride
                )
            },
            finalizeRedirections: { [self] routing, result, processSubstitutionStartIndex, commandName in
                try await finalizeSingleCommandRedirections(
                    routing,
                    result: result,
                    processSubstitutionStartIndex: processSubstitutionStartIndex,
                    commandName: commandName
                )
            },
            runWithScopedFileDescriptorRouting: { [self] routing, touchedFileDescriptors, operation in
                await runtime.runWithScopedFileDescriptorRouting(
                    routing,
                    touchedFileDescriptors: touchedFileDescriptors
                ) {
                    await operation()
                }
            },
            builtinPorts: shellRuntimeBuiltinPorts(),
            appendClosedPersistentOutputProcessSubstitutions: { [self] pathsBefore, result in
                try await appendClosedSingleCommandPersistentOutputProcessSubstitutions(
                    pathsBefore: pathsBefore,
                    to: result
                )
            },
            reentryPorts: shellRuntimeReentryPorts(),
            makeSubcommandRunner: { [self] in
                makeSubcommandRunner()
            },
            makeCommandLineRunner: { [self] in
                makeCommandLineRunner()
            },
            availableCommandNames: { [self] in
                availableCommandNames()
            },
            availableCommandLookupPaths: { [self] in
                availableCommandLookupPaths()
            },
            applyCommandStateChange: { [self] stateChange in
                applyStateChange(stateChange)
            }
        )
    }
}
