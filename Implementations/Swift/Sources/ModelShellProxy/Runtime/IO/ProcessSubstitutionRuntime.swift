import Foundation
import MSPCore

struct IOProcessSubstitutionEnvironment {
    var ensureTemporaryDirectory: (String) throws -> Bool
    var pathExists: (String) -> Bool
    var writeFile: (String, Data) throws -> Void
    var readFileIfAvailable: (String) throws -> Data
    var remove: (String, Bool) -> Void
    var isDirectoryEmpty: (String) -> Bool
    var redirectionFailure: (String) -> Error
}

extension ShellRuntime {
    func createProcessSubstitutionTemporaryPath(
        environment: IOProcessSubstitutionEnvironment
    ) throws -> String {
        try io.createProcessSubstitutionTemporaryPath(
            lifetime: &processSubstitutionLifetime,
            environment: environment
        )
    }

    func writeProcessSubstitutionInput(
        _ result: MSPCommandResult,
        to path: String,
        environment: IOProcessSubstitutionEnvironment
    ) throws {
        try io.writeProcessSubstitutionInput(result, to: path, environment: environment)
    }

    func registerOutputProcessSubstitution(path: String, command: String) {
        io.registerOutputProcessSubstitution(path: path, command: command)
    }

    func appendScopedOutputProcessSubstitutions(
        from startIndex: Int,
        to result: MSPCommandResult,
        environment: IOProcessSubstitutionEnvironment,
        runCommand: (String, Data) async -> MSPCommandResult
    ) async throws -> MSPCommandResult {
        var updated = result
        for path in io.scopedOutputProcessSubstitutionPaths(from: startIndex) {
            updated = IORuntimeState.mergeProcessSubstitutionResult(
                updated,
                try await finalizeOutputProcessSubstitution(
                    at: path,
                    removeAfterFinalizing: true,
                    environment: environment,
                    runCommand: runCommand
                )
            )
        }
        return updated
    }

    func appendClosedPersistentOutputProcessSubstitutions(
        pathsBefore: Set<String>,
        to result: MSPCommandResult,
        environment: IOProcessSubstitutionEnvironment,
        runCommand: (String, Data) async -> MSPCommandResult
    ) async throws -> MSPCommandResult {
        var updated = result
        for path in io.closedPersistentOutputProcessSubstitutionPaths(pathsBefore: pathsBefore) {
            updated = IORuntimeState.mergeProcessSubstitutionResult(
                updated,
                try await finalizeOutputProcessSubstitution(
                    at: path,
                    removeAfterFinalizing: true,
                    environment: environment,
                    runCommand: runCommand
                )
            )
        }
        return updated
    }

    func finalizeOutputProcessSubstitution(
        at path: String,
        removeAfterFinalizing: Bool,
        environment: IOProcessSubstitutionEnvironment,
        runCommand: (String, Data) async -> MSPCommandResult
    ) async throws -> MSPCommandResult {
        guard let substitution = io.outputProcessSubstitution(at: path) else {
            return .success()
        }
        let input = try environment.readFileIfAvailable(substitution.path)
        let result = await runCommand(substitution.command, input)
        if removeAfterFinalizing {
            io.removeOutputProcessSubstitution(at: path)
            environment.remove(path, false)
            processSubstitutionLifetime.cleanupTemporaryDirectories(
                livePaths: io.liveProcessSubstitutionPaths,
                environment: environment
            )
        }
        return result
    }

    func cleanupProcessSubstitutionTemporaryPaths(
        from startIndex: Int,
        environment: IOProcessSubstitutionEnvironment
    ) {
        io.cleanupProcessSubstitutionTemporaryPaths(
            from: startIndex,
            lifetime: &processSubstitutionLifetime,
            environment: environment
        )
    }
}

extension IORuntimeState {
    var processSubstitutionCheckpoint: Int {
        processSubstitutionTemporaryPaths.count
    }

    mutating func createProcessSubstitutionTemporaryPath(
        lifetime: inout ProcessSubstitutionLifetime,
        environment: IOProcessSubstitutionEnvironment
    ) throws -> String {
        if try environment.ensureTemporaryDirectory("/tmp") {
            lifetime.recordCreatedTemporaryDirectory("/tmp")
        }
        for _ in 0..<100 {
            let path = "/tmp/msp-process-substitution.\(UUID().uuidString.lowercased())"
            if environment.pathExists(path) {
                continue
            }
            processSubstitutionTemporaryPaths.append(path)
            return path
        }
        throw environment.redirectionFailure("<(: failed to create process substitution file")
    }

    func writeProcessSubstitutionInput(
        _ result: MSPCommandResult,
        to path: String,
        environment: IOProcessSubstitutionEnvironment
    ) throws {
        try environment.writeFile(path, result.stdoutData)
    }

    mutating func registerOutputProcessSubstitution(path: String, command: String) {
        outputProcessSubstitutions[path] = MSPOutputProcessSubstitution(
            path: path,
            command: command
        )
    }

    func outputProcessSubstitution(at path: String) -> MSPOutputProcessSubstitution? {
        outputProcessSubstitutions[path]
    }

    mutating func removeOutputProcessSubstitution(at path: String) {
        outputProcessSubstitutions.removeValue(forKey: path)
    }

    var liveProcessSubstitutionPaths: Set<String> {
        Set(processSubstitutionTemporaryPaths).union(outputProcessSubstitutions.keys)
    }

    func scopedOutputProcessSubstitutionPaths(from startIndex: Int) -> [String] {
        guard startIndex < processSubstitutionTemporaryPaths.count else {
            return []
        }
        let persistentPaths = persistentOutputProcessSubstitutionPaths
        return processSubstitutionTemporaryPaths[startIndex...]
            .filter { outputProcessSubstitutions[$0] != nil && !persistentPaths.contains($0) }
    }

    func closedPersistentOutputProcessSubstitutionPaths(pathsBefore: Set<String>) -> [String] {
        pathsBefore.subtracting(persistentOutputProcessSubstitutionPaths).sorted()
    }

    mutating func cleanupProcessSubstitutionTemporaryPaths(
        from startIndex: Int,
        lifetime: inout ProcessSubstitutionLifetime,
        environment: IOProcessSubstitutionEnvironment
    ) {
        guard startIndex < processSubstitutionTemporaryPaths.count else {
            return
        }
        let persistentPaths = persistentOutputProcessSubstitutionPaths
        let paths = Array(processSubstitutionTemporaryPaths[startIndex...])
        processSubstitutionTemporaryPaths.removeSubrange(startIndex...)
        for path in paths where !persistentPaths.contains(path) {
            outputProcessSubstitutions.removeValue(forKey: path)
            environment.remove(path, false)
        }
        lifetime.cleanupTemporaryDirectories(
            livePaths: liveProcessSubstitutionPaths,
            environment: environment
        )
    }

    static func mergeProcessSubstitutionResult(
        _ lhs: MSPCommandResult,
        _ rhs: MSPCommandResult
    ) -> MSPCommandResult {
        var stdoutData = lhs.stdoutData
        stdoutData.append(rhs.stdoutData)
        var stderrData = lhs.stderrData
        stderrData.append(rhs.stderrData)
        return MSPCommandResult(
            stdoutData: stdoutData,
            stderrData: stderrData,
            exitCode: rhs.exitCode == 0 ? lhs.exitCode : rhs.exitCode,
            stateChange: lhs.stateChange ?? rhs.stateChange,
            modelContentItems: lhs.modelContentItems + rhs.modelContentItems
        )
    }
}

extension ProcessSubstitutionLifetime {
    mutating func cleanupTemporaryDirectories(
        livePaths: Set<String>,
        environment: IOProcessSubstitutionEnvironment
    ) {
        guard !createdTemporaryDirectories.isEmpty else {
            return
        }
        for directory in createdTemporaryDirectories.sorted(by: >) {
            guard !livePaths.contains(where: { Self.isProcessSubstitutionPath($0, inside: directory) }) else {
                continue
            }
            guard environment.isDirectoryEmpty(directory) else {
                continue
            }
            environment.remove(directory, true)
            if !environment.pathExists(directory) {
                forgetCreatedTemporaryDirectory(directory)
            }
        }
    }

    private static func isProcessSubstitutionPath(_ path: String, inside directory: String) -> Bool {
        path == directory || path.hasPrefix(directory + "/")
    }
}
