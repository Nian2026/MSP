import Foundation
import MSPCore
import MSPShell

struct RuntimeExecPersistentBindingSnapshot {
    var stdoutBinding: MSPRedirectionOutputBinding
    var stderrBinding: MSPRedirectionOutputBinding
    var outputFileDescriptors: [Int: MSPRedirectionOutputBinding]
    var inputFileDescriptors: [Int: Int]
    var closedInputFileDescriptors: Set<Int>
    var inputOpenFileDescriptions: [Int: MSPShellInputOpenFileDescription]
    var nextInputOpenFileID: Int
}

typealias RuntimeExecPersistentRedirectionApplier = (
    _ redirections: [MSPParsedRedirection],
    _ standardInput: inout Data,
    _ standardInputClosed: inout Bool
) throws -> Void

extension RuntimeBuiltinContext {
    mutating func executeExecCommand(
        arguments: [String],
        redirections: [MSPParsedRedirection],
        appliesStateChange: Bool,
        snapshotPersistentBindings: () -> RuntimeExecPersistentBindingSnapshot,
        restorePersistentBindings: (RuntimeExecPersistentBindingSnapshot) -> Void,
        applyPersistentRedirections: RuntimeExecPersistentRedirectionApplier
    ) -> MSPCommandResult {
        guard arguments.isEmpty else {
            return .failure(exitCode: 126, stderr: "exec: command replacement is not supported\n")
        }

        let previousStandardInput = configuration.standardInput
        let previousStandardInputClosed = configuration.standardInputClosed
        let previousBindings = snapshotPersistentBindings()

        do {
            try applyPersistentRedirections(
                redirections,
                &configuration.standardInput,
                &configuration.standardInputClosed
            )
            if !appliesStateChange {
                configuration.standardInput = previousStandardInput
                configuration.standardInputClosed = previousStandardInputClosed
                restorePersistentBindings(previousBindings)
            }
            return .success()
        } catch let failure as MSPCommandFailure {
            if !appliesStateChange {
                configuration.standardInput = previousStandardInput
                configuration.standardInputClosed = previousStandardInputClosed
                restorePersistentBindings(previousBindings)
            }
            return failure.result
        } catch {
            if !appliesStateChange {
                configuration.standardInput = previousStandardInput
                configuration.standardInputClosed = previousStandardInputClosed
                restorePersistentBindings(previousBindings)
            }
            return .failure(exitCode: 1, stderr: "exec: \(error)\n")
        }
    }
}
