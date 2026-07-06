import Foundation
import MSPCore
import MSPShell

extension ModelShellProxy {
    var persistentStdoutBinding: MSPRedirectionOutputBinding {
        get { runtime.io.persistentStdoutBinding }
        set { runtime.io.persistentStdoutBinding = newValue }
    }

    var persistentStderrBinding: MSPRedirectionOutputBinding {
        get { runtime.io.persistentStderrBinding }
        set { runtime.io.persistentStderrBinding = newValue }
    }

    var persistentInputFileDescriptors: [Int: Int] {
        get { runtime.io.persistentInputFileDescriptors }
        set { runtime.io.persistentInputFileDescriptors = newValue }
    }

    var persistentClosedInputFileDescriptors: Set<Int> {
        get { runtime.io.persistentClosedInputFileDescriptors }
        set { runtime.io.persistentClosedInputFileDescriptors = newValue }
    }

    func applySingleCommandRedirections(
        _ redirections: [MSPParsedRedirection],
        standardInput: Data,
        standardInputClosed: Bool,
        standardInputOverridesFileDescriptor: Bool,
        currentDirectory: String,
        stdoutBindingOverride: MSPRedirectionOutputBinding?,
        stderrBindingOverride: MSPRedirectionOutputBinding?
    ) throws -> MSPRedirectionRouting {
        try applyRedirections(
            redirections,
            standardInput: standardInput,
            standardInputClosed: standardInputClosed,
            standardInputOverridesFileDescriptor: standardInputOverridesFileDescriptor,
            currentDirectory: currentDirectory,
            stdoutBindingOverride: stdoutBindingOverride,
            stderrBindingOverride: stderrBindingOverride
        )
    }

    func finalizeSingleCommandRedirections(
        _ routing: MSPRedirectionRouting,
        result: MSPCommandResult,
        processSubstitutionStartIndex: Int,
        commandName: String?
    ) async throws -> MSPCommandResult {
        try await finalizeRedirections(
            routing,
            result: result,
            processSubstitutionStartIndex: processSubstitutionStartIndex,
            commandName: commandName
        )
    }

    func pipelineFileOutputStream(
        for sink: MSPRedirectionFileSink
    ) -> (any MSPCommandOutputStream)? {
        guard let fileSystem = try? workspaceFileSystemForRedirection() else {
            return nil
        }
        return MSPWorkspaceFileOutputStream(
            fileSystem: fileSystem,
            path: sink.path,
            currentDirectory: "/",
            creationMode: regularFileCreationMode()
        )
    }

    func applyPipelineRedirections(
        _ redirections: [MSPParsedRedirection],
        standardInput: Data,
        standardInputClosed: Bool,
        standardInputOverridesFileDescriptor: Bool,
        currentDirectory: String,
        stdoutBindingOverride: MSPRedirectionOutputBinding?,
        stderrBindingOverride: MSPRedirectionOutputBinding?
    ) throws -> MSPRedirectionRouting {
        try applyRedirections(
            redirections,
            standardInput: standardInput,
            standardInputClosed: standardInputClosed,
            standardInputOverridesFileDescriptor: standardInputOverridesFileDescriptor,
            currentDirectory: currentDirectory,
            stdoutBindingOverride: stdoutBindingOverride,
            stderrBindingOverride: stderrBindingOverride
        )
    }

    func emitPipelineRedirectionOutput(
        _ data: Data,
        to binding: MSPRedirectionOutputBinding,
        visibleStdout: inout Data,
        visibleStderr: inout Data,
        writtenFilePaths: inout Set<String>
    ) throws {
        try emitRedirectionOutput(
            data,
            to: binding,
            visibleStdout: &visibleStdout,
            visibleStderr: &visibleStderr,
            writtenFilePaths: &writtenFilePaths
        )
    }

    func applyRedirections(
        _ redirections: [MSPParsedRedirection],
        standardInput: Data,
        standardInputClosed: Bool = false,
        standardInputOverridesFileDescriptor: Bool = false,
        currentDirectory: String,
        stdoutBindingOverride: MSPRedirectionOutputBinding? = nil,
        stderrBindingOverride: MSPRedirectionOutputBinding? = nil
    ) throws -> MSPRedirectionRouting {
        try runtime.io.applyRedirections(
            redirections,
            standardInput: standardInput,
            standardInputClosed: standardInputClosed,
            standardInputOverridesFileDescriptor: standardInputOverridesFileDescriptor,
            stdoutBindingOverride: stdoutBindingOverride,
            stderrBindingOverride: stderrBindingOverride,
            environment: redirectionEnvironment(currentDirectory: currentDirectory)
        )
    }

    func finalizeRedirections(
        _ routing: MSPRedirectionRouting,
        result: MSPCommandResult,
        processSubstitutionStartIndex: Int,
        commandName: String? = nil
    ) async throws -> MSPCommandResult {
        var updated = result
        var visibleStdout = Data()
        var visibleStderr = Data()
        var writtenFilePaths = Set<String>()
        try emitRedirectionOutput(
            updated.stdoutData,
            to: routing.stdoutBinding,
            visibleStdout: &visibleStdout,
            visibleStderr: &visibleStderr,
            writtenFilePaths: &writtenFilePaths,
            commandName: commandName,
            closedReason: "standard output: Bad file descriptor"
        )
        try emitRedirectionOutput(
            updated.stderrData,
            to: routing.stderrBinding,
            visibleStdout: &visibleStdout,
            visibleStderr: &visibleStderr,
            writtenFilePaths: &writtenFilePaths,
            commandName: commandName,
            closedReason: "standard error: Bad file descriptor"
        )
        updated.stdoutData = visibleStdout
        updated.stderrData = visibleStderr
        updated = try await appendScopedOutputProcessSubstitutions(
            from: processSubstitutionStartIndex,
            to: updated
        )
        cleanupProcessSubstitutionTemporaryPaths(from: processSubstitutionStartIndex)
        return updated
    }

    func applyPersistentExecRedirections(
        _ redirections: [MSPParsedRedirection],
        standardInput: inout Data,
        standardInputClosed: inout Bool
    ) throws {
        try runtime.io.applyPersistentExecRedirections(
            redirections,
            standardInput: &standardInput,
            standardInputClosed: &standardInputClosed,
            environment: redirectionEnvironment(currentDirectory: configuration.currentDirectory)
        )
    }

    func emitRedirectionOutput(
        _ data: Data,
        to binding: MSPRedirectionOutputBinding,
        visibleStdout: inout Data,
        visibleStderr: inout Data,
        writtenFilePaths: inout Set<String>,
        commandName: String? = nil,
        closedReason: String = "Bad file descriptor"
    ) throws {
        try runtime.io.emitRedirectionOutput(
            data,
            to: binding,
            visibleStdout: &visibleStdout,
            visibleStderr: &visibleStderr,
            writtenFilePaths: &writtenFilePaths,
            commandName: commandName,
            closedReason: closedReason,
            environment: redirectionEnvironment(currentDirectory: configuration.currentDirectory)
        )
    }

    func remainingInputData(for descriptionID: Int) throws -> Data {
        do {
            return try runtime.io.remainingInputData(for: descriptionID) { virtualPath in
                try workspaceFileSystemForRedirection().readFile(virtualPath, from: "/")
            }
        } catch IORuntimeFailure.badFileDescriptor(let message) {
            throw redirectionFailure(message)
        }
    }

    func consumeInputOpenFileDescription(id: Int, byteCount: Int) {
        runtime.io.consumeInputOpenFileDescription(id: id, byteCount: byteCount)
    }

    func readCommandInput(
        for fd: Int,
        routing: MSPRedirectionRouting,
        mode: RuntimeBuiltinInputReadMode
    ) async throws -> (data: Data, descriptionID: Int?) {
        guard fd == 0,
              routing.standardInputDescriptor == nil,
              !routing.standardInputClosed
        else {
            return try runtime.io.readCommandInput(
                for: fd,
                routing: routing,
                environment: redirectionEnvironment(currentDirectory: configuration.currentDirectory)
            )
        }

        var data = routing.standardInput
        if inputData(data, satisfies: mode) {
            return (data, nil)
        }

        guard let stream = configuration.standardInputStream else {
            return (data, nil)
        }
        while let chunk = try await stream.read(maxBytes: 32 * 1024) {
            data.append(chunk)
            if inputData(data, satisfies: mode) {
                break
            }
        }
        return (data, nil)
    }

    private func inputData(_ data: Data, satisfies mode: RuntimeBuiltinInputReadMode) -> Bool {
        switch mode {
        case .all:
            return false
        case .record(let delimiter, let characterCount, let timeoutIsZero):
            if timeoutIsZero {
                return true
            }
            let text = String(decoding: data, as: UTF8.self)
            if let characterCount {
                return text.count >= characterCount
            }
            return text.contains(delimiter)
        }
    }
}
