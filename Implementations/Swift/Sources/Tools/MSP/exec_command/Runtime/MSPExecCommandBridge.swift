import Foundation
import MSPCore

public typealias MSPExecCommandRunner = @Sendable (_ cmd: String) async -> MSPCommandResult
public typealias MSPExecCommandOutputHandler = @Sendable (_ event: MSPExecCommandOutputEvent) async -> Void
public typealias MSPExecCommandStreamingRunner = @Sendable (
    _ call: MSPExecCommandCall,
    _ outputHandler: MSPExecCommandOutputHandler?
) async -> MSPCommandResult

public enum MSPExecCommandOutputStreamName: String, Hashable, Codable, Sendable {
    case stdout
    case stderr
}

public struct MSPExecCommandOutputEvent: Hashable, Sendable {
    public var stream: MSPExecCommandOutputStreamName
    public var text: String

    public init(stream: MSPExecCommandOutputStreamName, text: String) {
        self.stream = stream
        self.text = text
    }
}

public struct MSPExecCommandBridge: Sendable {
    public let runCommand: MSPExecCommandRunner
    private let runStreamingCommand: MSPExecCommandStreamingRunner
    private let sessionCoordinator: MSPExecCommandSessionCoordinator?

    public init(runCommand: @escaping MSPExecCommandRunner) {
        self.runCommand = runCommand
        self.runStreamingCommand = { call, _ in
            await runCommand(call.cmd)
        }
        self.sessionCoordinator = nil
    }

    public init(runStreamingCommand: @escaping MSPExecCommandStreamingRunner) {
        self.runCommand = { cmd in
            await runStreamingCommand(MSPExecCommandCall(cmd: cmd), nil)
        }
        self.runStreamingCommand = runStreamingCommand
        self.sessionCoordinator = nil
    }

    public init(sessionCoordinator: MSPExecCommandSessionCoordinator) {
        self.runCommand = { _ in
            .failure(
                exitCode: 1,
                stderr: "exec_command session coordinator requires MSPExecCommandCall\n"
            )
        }
        self.runStreamingCommand = { call, outputHandler in
            let read = await sessionCoordinator.exec(call, onOutput: outputHandler)
            return read.result
        }
        self.sessionCoordinator = sessionCoordinator
    }

    public func run(
        _ call: MSPExecCommandCall,
        onOutput: MSPExecCommandOutputHandler? = nil
    ) async -> MSPCommandResult {
        await runStreamingCommand(call, onOutput)
    }

    public func call(_ call: MSPExecCommandCall) async -> String {
        let result = await run(call)
        return MSPExecCommandRenderer.renderAgentText(
            from: result,
            options: MSPExecCommandRenderOptions(maxOutputTokens: call.maxOutputTokens)
        )
    }

    public func call(arguments: [String: String]) async throws -> String {
        try await call(MSPExecCommandCall(arguments: arguments))
    }

    public func runSession(
        _ call: MSPExecCommandCall,
        onOutput: MSPExecCommandOutputHandler? = nil
    ) async -> MSPExecCommandSessionRead {
        if let sessionCoordinator {
            return await sessionCoordinator.exec(call, onOutput: onOutput)
        }
        let startedAt = Date()
        let result = await run(call, onOutput: onOutput)
        return MSPExecCommandSessionRead(
            result: result,
            wallTimeSeconds: Date().timeIntervalSince(startedAt),
            exitCode: result.exitCode
        )
    }

    public func writeStdin(
        _ call: MSPWriteStdinCall,
        onOutput: MSPExecCommandOutputHandler? = nil
    ) async -> MSPExecCommandSessionRead {
        guard let sessionCoordinator else {
            return MSPExecCommandSessionRead(
                result: .failure(
                    exitCode: 1,
                    stderr: "write_stdin failed: exec_command bridge has no session coordinator\n"
                ),
                exitCode: 1
            )
        }
        return await sessionCoordinator.writeStdin(call, onOutput: onOutput)
    }

    public func readSession(
        sessionID: Int,
        waitMilliseconds: Int? = nil,
        onOutput: MSPExecCommandOutputHandler? = nil
    ) async -> MSPExecCommandSessionRead {
        guard let sessionCoordinator else {
            return MSPExecCommandSessionRead(
                result: .failure(
                    exitCode: 1,
                    stderr: "read failed: exec_command bridge has no session coordinator\n"
                ),
                exitCode: 1
            )
        }
        return await sessionCoordinator.read(
            sessionID: sessionID,
            waitMilliseconds: waitMilliseconds,
            onOutput: onOutput
        )
    }

    public func terminateSession(_ sessionID: Int) async -> MSPExecCommandSessionRead {
        guard let sessionCoordinator else {
            return MSPExecCommandSessionRead(
                result: .failure(
                    exitCode: 1,
                    stderr: "terminate failed: exec_command bridge has no session coordinator\n"
                ),
                exitCode: 1
            )
        }
        return await sessionCoordinator.terminate(sessionID: sessionID)
    }

    public func callSession(_ call: MSPExecCommandCall) async -> String {
        let read = await runSession(call)
        return MSPExecCommandRenderer.renderAgentText(
            from: read,
            options: MSPExecCommandRenderOptions(maxOutputTokens: call.maxOutputTokens)
        )
    }

    public func callWriteStdin(_ call: MSPWriteStdinCall) async -> String {
        let read = await writeStdin(call)
        return MSPExecCommandRenderer.renderAgentText(
            from: read,
            options: MSPExecCommandRenderOptions(maxOutputTokens: call.maxOutputTokens)
        )
    }
}
