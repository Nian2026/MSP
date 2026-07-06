@_exported import MSPCore
@_exported import MSPCommandKit
@_exported import MSPExternalRunner
@_exported import MSPAgentBridge

import Foundation
import MSPApple
import MSPShell

public final class ModelShellProxy {
    let runtime: ShellRuntime
    private let streamProbesEnabled: Bool
    var registry: MSPCommandRegistry {
        runtime.registry
    }
    var configuration: MSPConfiguration {
        get { runtime.configuration }
        set { runtime.configuration = newValue }
    }
    var parser: MSPShellParser {
        runtime.parser
    }

    public init(
        configuration: MSPConfiguration = MSPConfiguration(),
        registry: MSPCommandRegistry = try! MSPCommandRegistry(),
        parser: MSPShellParser = MSPShellParser()
    ) {
        self.streamProbesEnabled = Self.streamProbeEnabled(environment: configuration.environment)
        self.runtime = ShellRuntime(
            configuration: ShellRuntimeConfiguration(
                shell: configuration,
                registry: registry,
                parser: parser
            )
        )
    }

    public static func iOS(workspaceURL: URL) throws -> ModelShellProxy {
        let workspace = try MSPAppleWorkspace(rootURL: workspaceURL)
        return ModelShellProxy(configuration: MSPConfiguration(workspace: workspace))
    }

    @discardableResult
    public func enable(_ profile: MSPProfile) throws -> ModelShellProxy {
        try profile.registerCommands(into: registry)
        return self
    }

    @discardableResult
    public func enable(_ commandPack: any MSPCommandPack) throws -> ModelShellProxy {
        try commandPack.registerCommands(into: registry)
        return self
    }

    @discardableResult
    public func register(
        _ name: String,
        summary: String? = nil,
        handler: @escaping MSPCommandHandler
    ) throws -> ModelShellProxy {
        try registry.register(name, summary: summary, handler: handler)
        return self
    }

    @discardableResult
    public func registerExternalCommand(
        _ name: String,
        summary: String? = nil,
        commandLookupPaths: [String] = [],
        runner: any MSPExternalCommandRunner
    ) throws -> ModelShellProxy {
        try registry.registerExternalCommand(
            name,
            summary: summary,
            commandLookupPaths: commandLookupPaths,
            runner: runner
        )
        return self
    }

    public func run(
        _ commandLine: String,
        outputStream: (any MSPCommandOutputStream)? = nil,
        errorStream: (any MSPCommandOutputStream)? = nil
    ) async -> MSPCommandResult {
        await run(
            commandLine,
            initialLastExitCode: 0,
            clearsShellControlAtEnd: true,
            outputStream: outputStream,
            errorStream: errorStream
        )
    }

    func run(
        _ commandLine: String,
        initialLastExitCode: Int32,
        clearsShellControlAtEnd: Bool = false,
        suppressesErrexit: Bool = false,
        sourceLineOffset: Int = 0,
        syntaxDiagnosticCommandName: String? = nil,
        standardInput: Data? = nil,
        standardInputClosed: Bool? = nil,
        outputStream: (any MSPCommandOutputStream)? = nil,
        errorStream: (any MSPCommandOutputStream)? = nil
    ) async -> MSPCommandResult {
        let previousStandardInput = configuration.standardInput
        let previousStandardInputClosed = configuration.standardInputClosed
        if let standardInput {
            configuration.standardInput = standardInput
        }
        if let standardInputClosed {
            configuration.standardInputClosed = standardInputClosed
        }
        let result = await runtime.runCommandListLine(
            commandLine,
            options: ShellRuntimeCommandListRunOptions(
                initialLastExitCode: initialLastExitCode,
                clearsShellControlAtEnd: clearsShellControlAtEnd,
                suppressesErrexit: suppressesErrexit,
                sourceLineOffset: sourceLineOffset,
                syntaxDiagnosticCommandName: syntaxDiagnosticCommandName,
                outputStream: outputStream,
                errorStream: errorStream
            ),
            ports: commandListRuntimePorts()
        )
        if standardInput != nil {
            configuration.standardInput = previousStandardInput
        }
        if standardInputClosed != nil {
            configuration.standardInputClosed = previousStandardInputClosed
        }
        return result
    }

    func run(
        _ commandList: MSPParsedCommandList,
        initialLastExitCode: Int32,
        clearsShellControlAtEnd: Bool = false,
        suppressesErrexit: Bool = false,
        sourceLineOffset: Int = 0,
        outputStream: (any MSPCommandOutputStream)? = nil,
        errorStream: (any MSPCommandOutputStream)? = nil
    ) async -> MSPCommandResult {
        await runtime.runCommandList(
            commandList,
            options: ShellRuntimeCommandListRunOptions(
                initialLastExitCode: initialLastExitCode,
                clearsShellControlAtEnd: clearsShellControlAtEnd,
                suppressesErrexit: suppressesErrexit,
                sourceLineOffset: sourceLineOffset,
                syntaxDiagnosticCommandName: nil,
                outputStream: outputStream,
                errorStream: errorStream
            ),
            ports: commandListRuntimePorts()
        )
    }

    private func commandListRuntimePorts() -> ShellRuntimeCommandListPorts {
        ShellRuntimeCommandListPorts(
            runPipeline: { [self] parsed, fullCommandLine, lastExitCode, sourceLineNumber, outputStream, errorStream in
                await runtime.runPipeline(
                    parsed,
                    options: ShellRuntimePipelineRunOptions(
                        fullCommandLine: fullCommandLine,
                        lastExitCode: lastExitCode,
                        sourceLineNumber: sourceLineNumber,
                        outputStream: outputStream,
                        errorStream: errorStream
                    ),
                    ports: pipelineRuntimePorts()
                )
            },
            runExitTrap: { [self] finalExitCode in
                await runtime.runExitTrapIfNeeded(
                    finalExitCode: finalExitCode,
                    ports: exitTrapRuntimePorts()
                )
            }
        )
    }

    func emitStreamProbe(_ event: String, fields: [String: String]) {
        guard streamProbesEnabled else {
            return
        }
        let renderedFields = fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let suffix = renderedFields.isEmpty ? "" : " \(renderedFields)"
        FileHandle.standardError.write(Data("[MSP_SHELL_STREAM_PROBE] \(event)\(suffix)\n".utf8))
    }

    private static func streamProbeEnabled(environment: [String: String]) -> Bool {
        let rawValue = environment["MSP_SHELL_STREAM_PROBES"]
            ?? ProcessInfo.processInfo.environment["MSP_SHELL_STREAM_PROBES"]
            ?? ""
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    func applyStateChange(_ stateChange: MSPCommandRuntimeStateChange?) {
        guard let stateChange else {
            return
        }
        if let currentDirectory = stateChange.currentDirectory {
            let previousDirectory = configuration.currentDirectory
            configuration.currentDirectory = currentDirectory
            configuration.environment["OLDPWD"] = previousDirectory
            configuration.environment["PWD"] = currentDirectory
        }
    }

    func makeIsolatedSessionShell() -> ModelShellProxy {
        let snapshot = runtime.captureState()
        let isolated = ModelShellProxy(
            configuration: snapshot.configuration,
            registry: registry,
            parser: parser
        )
        isolated.runtime.restoreState(snapshot)
        return isolated
    }

    func availableCommandNames() -> [String] {
        Array(Set(registry.commandNames)
            .union(runtime.shellFunctionNames())
            .union(ShellRuntime.runtimeSpecialBuiltinNames))
            .sorted()
    }

    func availableCommandLookupPaths() -> [String: [String]] {
        registry.commandLookupPaths
    }

    func exportedEnvironment(
        from base: [String: String]? = nil,
        applying assignments: [MSPParsedAssignment] = []
    ) -> [String: String] {
        runtime.exportedEnvironment(from: base, applying: assignments)
    }
}
