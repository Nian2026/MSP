import Foundation
import MSPCore
import MSPShell

extension ModelShellProxy {
    func resolveSingleCommandProcessSubstitution(
        _ request: MSPShellProcessSubstitutionRequest,
        standardInput: Data,
        standardInputClosed: Bool,
        standardInputOverridesFileDescriptor: Bool,
        lastExitCode: Int32
    ) async throws -> MSPShellProcessSubstitutionResult {
        try await resolveProcessSubstitution(
            request,
            standardInput: standardInput,
            standardInputClosed: standardInputClosed,
            standardInputOverridesFileDescriptor: standardInputOverridesFileDescriptor,
            lastExitCode: lastExitCode
        )
    }

    func cleanupSingleCommandProcessSubstitutionTemporaryPaths(from startIndex: Int) {
        cleanupProcessSubstitutionTemporaryPaths(from: startIndex)
    }

    func appendClosedSingleCommandPersistentOutputProcessSubstitutions(
        pathsBefore: Set<String>,
        to result: MSPCommandResult
    ) async throws -> MSPCommandResult {
        try await appendClosedPersistentOutputProcessSubstitutions(
            pathsBefore: pathsBefore,
            to: result
        )
    }

    func resolvePipelineProcessSubstitution(
        _ request: MSPShellProcessSubstitutionRequest,
        standardInput: Data,
        standardInputClosed: Bool,
        standardInputOverridesFileDescriptor: Bool,
        lastExitCode: Int32
    ) async throws -> MSPShellProcessSubstitutionResult {
        try await resolveProcessSubstitution(
            request,
            standardInput: standardInput,
            standardInputClosed: standardInputClosed,
            standardInputOverridesFileDescriptor: standardInputOverridesFileDescriptor,
            lastExitCode: lastExitCode
        )
    }

    func cleanupPipelineProcessSubstitutions(from startIndex: Int) {
        cleanupProcessSubstitutionTemporaryPaths(from: startIndex)
    }

    func resolveProcessSubstitution(
        _ request: MSPShellProcessSubstitutionRequest,
        standardInput: Data,
        standardInputClosed: Bool = false,
        standardInputOverridesFileDescriptor: Bool = false,
        lastExitCode: Int32
    ) async throws -> MSPShellProcessSubstitutionResult {
        let environment = processSubstitutionEnvironment()
        let path = try runtime.createProcessSubstitutionTemporaryPath(environment: environment)
        switch request.mode {
        case .input:
            let result = await runProcessSubstitutionCommand(
                request.command,
                standardInput: standardInput,
                standardInputClosed: standardInputClosed,
                standardInputOverridesFileDescriptor: standardInputOverridesFileDescriptor,
                lastExitCode: lastExitCode
            )
            try runtime.writeProcessSubstitutionInput(result, to: path, environment: environment)
            return MSPShellProcessSubstitutionResult(path: path, stderr: result.stderr)
        case .output:
            runtime.registerOutputProcessSubstitution(path: path, command: request.command)
            return MSPShellProcessSubstitutionResult(path: path)
        }
    }

    func appendScopedOutputProcessSubstitutions(
        from startIndex: Int,
        to result: MSPCommandResult
    ) async throws -> MSPCommandResult {
        try await runtime.appendScopedOutputProcessSubstitutions(
            from: startIndex,
            to: result,
            environment: processSubstitutionEnvironment()
        ) { [self] command, input in
            await runProcessSubstitutionCommand(
                command,
                standardInput: input,
                standardInputOverridesFileDescriptor: true,
                lastExitCode: 0
            )
        }
    }

    func appendClosedPersistentOutputProcessSubstitutions(
        pathsBefore: Set<String>,
        to result: MSPCommandResult
    ) async throws -> MSPCommandResult {
        try await runtime.appendClosedPersistentOutputProcessSubstitutions(
            pathsBefore: pathsBefore,
            to: result,
            environment: processSubstitutionEnvironment()
        ) { [self] command, input in
            await runProcessSubstitutionCommand(
                command,
                standardInput: input,
                standardInputOverridesFileDescriptor: true,
                lastExitCode: 0
            )
        }
    }

    func finalizeOutputProcessSubstitution(
        at path: String,
        removeAfterFinalizing: Bool
    ) async throws -> MSPCommandResult {
        try await runtime.finalizeOutputProcessSubstitution(
            at: path,
            removeAfterFinalizing: removeAfterFinalizing,
            environment: processSubstitutionEnvironment()
        ) { [self] command, input in
            await runProcessSubstitutionCommand(
                command,
                standardInput: input,
                standardInputOverridesFileDescriptor: true,
                lastExitCode: 0
            )
        }
    }

    func cleanupProcessSubstitutionTemporaryPaths(from startIndex: Int) {
        runtime.cleanupProcessSubstitutionTemporaryPaths(
            from: startIndex,
            environment: processSubstitutionEnvironment()
        )
    }
}
