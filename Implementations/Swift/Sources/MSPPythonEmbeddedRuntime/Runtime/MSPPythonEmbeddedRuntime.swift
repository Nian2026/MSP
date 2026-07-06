@_exported import MSPPythonRuntime
import Foundation
import MSPCore

public protocol MSPPythonEmbeddedEngine: Sendable {
    func runPython(
        request: MSPPythonEmbeddedExecutionRequest
    ) async throws -> MSPPythonEmbeddedExecutionResult
}

public protocol MSPPythonStreamingEmbeddedEngine: MSPPythonEmbeddedEngine {
    func runPythonStreaming(
        request: MSPPythonEmbeddedExecutionRequest
    ) async throws -> MSPPythonEmbeddedExecutionResult
}

public struct MSPPythonEmbeddedRuntime: MSPPythonRuntime {
    public var engine: any MSPPythonEmbeddedEngine

    public init(engine: any MSPPythonEmbeddedEngine) {
        self.engine = engine
    }

    public func runPython(
        request: MSPPythonExecutionRequest,
        context: MSPCommandContext
    ) async -> MSPCommandResult {
        let embeddedRequest = makeEmbeddedRequest(request: request, context: context)
        do {
            return try await engine.runPython(request: embeddedRequest).commandResult
        } catch let error as MSPPythonEmbeddedRuntimeError {
            return error.commandResult(commandName: request.invocation.commandName)
        } catch {
            return .failure(
                exitCode: 1,
                stderr: "\(request.invocation.commandName): \(error)\n"
            )
        }
    }

    public func runPythonStreaming(
        request: MSPPythonExecutionRequest,
        context: MSPCommandContext
    ) async -> MSPCommandResult {
        guard let streamingEngine = engine as? any MSPPythonStreamingEmbeddedEngine,
              !request.entrypoint.requiresBufferedStandardInputSource else {
            do {
                let bufferedContext = try await MSPPythonStreamingRuntimeSupport
                    .contextByBufferingStandardInputStream(context)
                return await runPython(request: request, context: bufferedContext)
            } catch {
                return .failure(
                    exitCode: 1,
                    stderr: "\(request.invocation.commandName): \(error)\n"
                )
            }
        }
        let embeddedRequest = makeEmbeddedRequest(request: request, context: context)
        do {
            return try await streamingEngine.runPythonStreaming(request: embeddedRequest).commandResult
        } catch let error as MSPPythonEmbeddedRuntimeError {
            return error.commandResult(commandName: request.invocation.commandName)
        } catch {
            return .failure(
                exitCode: 1,
                stderr: "\(request.invocation.commandName): \(error)\n"
            )
        }
    }

    private func makeEmbeddedRequest(
        request: MSPPythonExecutionRequest,
        context: MSPCommandContext
    ) -> MSPPythonEmbeddedExecutionRequest {
        MSPPythonEmbeddedExecutionRequest(
            invocation: request.invocation,
            entrypoint: request.entrypoint,
            virtualCurrentDirectory: request.virtualCurrentDirectory,
            workspace: context.workspace,
            environment: context.environment,
            standardInput: context.standardInput,
            standardInputClosed: context.standardInputClosed,
            standardInputStream: context.standardInputStream,
            standardOutputStream: context.standardOutputStream,
            standardErrorStream: context.standardErrorStream,
            fileCreationMask: context.fileCreationMask,
            subprocessContext: context
        )
    }
}

public struct MSPPythonEmbeddedExecutionRequest: Sendable {
    public var invocation: MSPPythonInvocation
    public var entrypoint: MSPPythonEntrypoint
    public var virtualCurrentDirectory: String
    public var workspace: (any MSPWorkspace)?
    public var environment: [String: String]
    public var standardInput: Data
    public var standardInputClosed: Bool
    public var standardInputStream: (any MSPCommandInputStream)?
    public var standardOutputStream: (any MSPCommandOutputStream)?
    public var standardErrorStream: (any MSPCommandOutputStream)?
    public var fileCreationMask: UInt16
    public var subprocessContext: MSPCommandContext

    public init(
        invocation: MSPPythonInvocation,
        entrypoint: MSPPythonEntrypoint,
        virtualCurrentDirectory: String,
        workspace: (any MSPWorkspace)?,
        environment: [String: String],
        standardInput: Data,
        standardInputClosed: Bool,
        standardInputStream: (any MSPCommandInputStream)? = nil,
        standardOutputStream: (any MSPCommandOutputStream)? = nil,
        standardErrorStream: (any MSPCommandOutputStream)? = nil,
        fileCreationMask: UInt16,
        subprocessContext: MSPCommandContext
    ) {
        self.invocation = invocation
        self.entrypoint = entrypoint
        self.virtualCurrentDirectory = virtualCurrentDirectory
        self.workspace = workspace
        self.environment = environment
        self.standardInput = standardInput
        self.standardInputClosed = standardInputClosed
        self.standardInputStream = standardInputStream
        self.standardOutputStream = standardOutputStream
        self.standardErrorStream = standardErrorStream
        self.fileCreationMask = fileCreationMask & 0o777
        self.subprocessContext = subprocessContext
    }
}

private extension MSPPythonEntrypoint {
    var requiresBufferedStandardInputSource: Bool {
        if case .standardInput = self {
            return true
        }
        return false
    }
}

public struct MSPPythonEmbeddedExecutionResult: Sendable, Equatable {
    public var stdoutData: Data
    public var stderrData: Data
    public var exitCode: Int32

    public init(
        stdoutData: Data = Data(),
        stderrData: Data = Data(),
        exitCode: Int32 = 0
    ) {
        self.stdoutData = stdoutData
        self.stderrData = stderrData
        self.exitCode = exitCode
    }

    public init(
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32 = 0
    ) {
        self.stdoutData = Data(stdout.utf8)
        self.stderrData = Data(stderr.utf8)
        self.exitCode = exitCode
    }

    public var commandResult: MSPCommandResult {
        MSPCommandResult(
            stdoutData: stdoutData,
            stderrData: stderrData,
            exitCode: exitCode
        )
    }
}

public enum MSPPythonEmbeddedRuntimeError: Error, Sendable, Equatable {
    case engineUnavailable(String)

    func commandResult(commandName: String) -> MSPCommandResult {
        switch self {
        case .engineUnavailable(let reason):
            return .failure(
                exitCode: 126,
                stderr: "\(commandName): embedded Python engine unavailable: \(reason)\n"
            )
        }
    }
}
