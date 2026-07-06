import Foundation
import MSPCore

public struct MSPPythonInvocation: Sendable, Equatable {
    public var commandName: String
    public var arguments: [String]
    public var rawInput: String

    public init(commandName: String, arguments: [String], rawInput: String) {
        self.commandName = commandName
        self.arguments = arguments
        self.rawInput = rawInput
    }
}

public enum MSPPythonEntrypoint: Sendable, Equatable {
    case command(source: String, arguments: [String])
    case module(name: String, arguments: [String])
    case script(path: MSPPythonScriptPath, arguments: [String])
    case standardInput(arguments: [String])
    case interactive(arguments: [String])
}

public struct MSPPythonScriptPath: Sendable, Equatable {
    public var originalOperand: String
    public var virtualPath: String

    public init(originalOperand: String, virtualPath: String) {
        self.originalOperand = originalOperand
        self.virtualPath = virtualPath
    }
}

public struct MSPPythonExecutionRequest: Sendable, Equatable {
    public var invocation: MSPPythonInvocation
    public var entrypoint: MSPPythonEntrypoint
    public var virtualCurrentDirectory: String

    public init(
        invocation: MSPPythonInvocation,
        entrypoint: MSPPythonEntrypoint,
        virtualCurrentDirectory: String
    ) {
        self.invocation = invocation
        self.entrypoint = entrypoint
        self.virtualCurrentDirectory = virtualCurrentDirectory
    }
}

public protocol MSPPythonRuntime: Sendable {
    func runPython(
        request: MSPPythonExecutionRequest,
        context: MSPCommandContext
    ) async -> MSPCommandResult

    func runPythonStreaming(
        request: MSPPythonExecutionRequest,
        context: MSPCommandContext
    ) async -> MSPCommandResult
}

public extension MSPPythonRuntime {
    func runPythonStreaming(
        request: MSPPythonExecutionRequest,
        context: MSPCommandContext
    ) async -> MSPCommandResult {
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
}

public enum MSPPythonUTF8Environment {
    public static let defaults: [String: String] = [
        "PYTHONUTF8": "1",
        "PYTHONIOENCODING": "utf-8:surrogateescape"
    ]

    public static func applying(to environment: [String: String]) -> [String: String] {
        var updated = environment
        for (key, value) in defaults {
            updated[key] = value
        }
        return updated
    }
}
