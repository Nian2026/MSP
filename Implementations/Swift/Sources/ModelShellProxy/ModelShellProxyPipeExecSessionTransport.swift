import Foundation
import MSPAgentBridge
import MSPCore

actor ModelShellProxyExecCommandOutputDispatcher {
    private let outputHandler: MSPExecCommandOutputHandler?
    private var pendingEvents: [MSPExecCommandOutputEvent] = []
    private var pendingEventIndex = 0
    private var isDraining = false

    init(outputHandler: MSPExecCommandOutputHandler?) {
        self.outputHandler = outputHandler
    }

    func enqueue(_ event: MSPExecCommandOutputEvent) {
        guard outputHandler != nil else {
            return
        }
        pendingEvents.append(event)
        guard !isDraining else {
            return
        }
        isDraining = true
        Task {
            await self.drain()
        }
    }

    private func drain() async {
        while true {
            guard pendingEventIndex < pendingEvents.count else {
                pendingEvents.removeAll(keepingCapacity: true)
                pendingEventIndex = 0
                isDraining = false
                return
            }
            let event = pendingEvents[pendingEventIndex]
            pendingEventIndex += 1
            if pendingEventIndex > 1_024 {
                pendingEvents.removeFirst(pendingEventIndex)
                pendingEventIndex = 0
            }
            await outputHandler?(event)
        }
    }
}

actor ModelShellProxyPipeExecSessionTransport: MSPExecCommandSessionTransport {
    private static let interrupt = "\u{3}"
    private static let eof = UInt8(4)

    private struct Session {
        var startedAt: Date
        var stdinPipe: MSPAsyncBytePipe
        var stdinClosed = false
        var task: Task<MSPCommandResult, Never>?
        var stdoutBuffer = ModelShellProxySessionOutputBuffer()
        var stderrBuffer = ModelShellProxySessionOutputBuffer()
        var capturedStdoutStreamOutput = false
        var capturedStderrStreamOutput = false
        var completedResult: MSPCommandResult?
        var terminated = false
    }

    private let shell: ModelShellProxy
    private var sessions: [Int: Session] = [:]

    init(shell: ModelShellProxy) {
        self.shell = shell
    }

    func start(
        call: MSPExecCommandCall,
        sessionID: Int,
        onOutput: MSPExecCommandOutputHandler?
    ) async -> MSPExecCommandSessionRead {
        guard !call.tty else {
            return MSPExecCommandSessionRead(
                result: .failure(
                    exitCode: 1,
                    stderr: "exec_command tty=true requires the MSP PTY backend, which is not installed yet.\n"
                ),
                exitCode: 1
            )
        }

        let startedAt = Date()
        let stdinPipe = MSPAsyncBytePipe(maxBufferedChunks: 1024)
        sessions[sessionID] = Session(
            startedAt: startedAt,
            stdinPipe: stdinPipe
        )
        let outputDispatcher = ModelShellProxyExecCommandOutputDispatcher(
            outputHandler: onOutput
        )
        let stdoutStream = outputStream(
            sessionID: sessionID,
            stream: .stdout,
            outputDispatcher: outputDispatcher
        )
        let stderrStream = outputStream(
            sessionID: sessionID,
            stream: .stderr,
            outputDispatcher: outputDispatcher
        )
        let sessionShell = shell.makeIsolatedSessionShell()
        sessionShell.configuration.standardInput = Data()
        sessionShell.configuration.standardInputClosed = false
        sessionShell.configuration.standardInputStream = stdinPipe
        let task = Task { [sessionShell] in
            let result = await sessionShell.run(
                call.cmd,
                outputStream: stdoutStream,
                errorStream: stderrStream
            )
            await self.finish(sessionID: sessionID, result: result)
            return result
        }
        sessions[sessionID]?.task = task

        await waitForCompletionOrDeadline(
            sessionID: sessionID,
            milliseconds: MSPExecCommandYieldPolicy.execMilliseconds(call.yieldTimeMilliseconds)
        )
        return consumeRead(sessionID: sessionID)
    }

    func write(
        call: MSPWriteStdinCall,
        onOutput: MSPExecCommandOutputHandler?
    ) async -> MSPExecCommandSessionRead {
        guard let session = sessions[call.sessionID] else {
            return inactiveRead(sessionID: call.sessionID, operation: "write_stdin")
        }
        if session.completedResult != nil {
            return consumeRead(sessionID: call.sessionID)
        }
        if call.chars == Self.interrupt {
            return await interruptSession(sessionID: call.sessionID)
        }
        if !call.stdinBytes.isEmpty {
            let writeFailure = await writeInput(call.stdinBytes, sessionID: call.sessionID)
            if let writeFailure {
                return writeFailure
            }
        }

        await waitForCompletionOrDeadline(
            sessionID: call.sessionID,
            milliseconds: MSPExecCommandYieldPolicy.writeStdinMilliseconds(
                call.yieldTimeMilliseconds,
                isEmpty: call.stdinBytes.isEmpty
            )
        )
        return consumeRead(sessionID: call.sessionID)
    }

    func read(
        sessionID: Int,
        waitMilliseconds: Int?,
        onOutput: MSPExecCommandOutputHandler?
    ) async -> MSPExecCommandSessionRead {
        guard sessions[sessionID] != nil else {
            return inactiveRead(sessionID: sessionID, operation: "read")
        }
        await waitForCompletionOrDeadline(
            sessionID: sessionID,
            milliseconds: MSPExecCommandYieldPolicy.readExecMilliseconds(waitMilliseconds)
        )
        return consumeRead(sessionID: sessionID)
    }

    func terminate(sessionID: Int) async -> MSPExecCommandSessionRead {
        guard var session = sessions.removeValue(forKey: sessionID) else {
            return inactiveRead(sessionID: sessionID, operation: "terminate")
        }
        session.terminated = true
        session.task?.cancel()
        await session.stdinPipe.closeWrite()
        await session.stdinPipe.closeRead()
        let result = MSPCommandResult.failure(
            exitCode: 143,
            stdoutData: session.stdoutBuffer.drain(),
            stderr: String(decoding: session.stderrBuffer.drain(), as: UTF8.self) + "terminated\n"
        )
        return MSPExecCommandSessionRead(
            result: result,
            wallTimeSeconds: Date().timeIntervalSince(session.startedAt),
            exitCode: 143
        )
    }

    private func interruptSession(sessionID: Int) async -> MSPExecCommandSessionRead {
        guard var session = sessions.removeValue(forKey: sessionID) else {
            return inactiveRead(sessionID: sessionID, operation: "write_stdin")
        }
        session.terminated = true
        session.task?.cancel()
        await session.stdinPipe.closeWrite()
        await session.stdinPipe.closeRead()
        let stdout = session.stdoutBuffer.drain()
        let stderr = session.stderrBuffer.drain()
        return MSPExecCommandSessionRead(
            result: MSPCommandResult(
                stdoutData: stdout,
                stderrData: stderr,
                exitCode: 130
            ),
            wallTimeSeconds: Date().timeIntervalSince(session.startedAt),
            exitCode: 130,
            signal: 2
        )
    }

    private func writeInput(
        _ data: Data,
        sessionID: Int
    ) async -> MSPExecCommandSessionRead? {
        guard let session = sessions[sessionID] else {
            return inactiveRead(sessionID: sessionID, operation: "write_stdin")
        }
        guard !session.stdinClosed else {
            return MSPExecCommandSessionRead(
                result: .failure(
                    exitCode: 1,
                    stderr: "write_stdin target live MSP exec session \(sessionID) stdin is closed.\n"
                ),
                runningSessionID: sessionID
            )
        }

        let eofIndex = data.firstIndex(of: Self.eof)
        let inputData: Data
        if let eofIndex {
            inputData = Data(data[..<eofIndex])
        } else {
            inputData = data
        }
        do {
            if !inputData.isEmpty {
                try await session.stdinPipe.write(inputData)
            }
            if eofIndex != nil {
                await session.stdinPipe.closeWrite()
                guard var latestSession = sessions[sessionID] else {
                    return inactiveRead(sessionID: sessionID, operation: "write_stdin")
                }
                latestSession.stdinClosed = true
                sessions[sessionID] = latestSession
            }
            return nil
        } catch {
            return MSPExecCommandSessionRead(
                result: .failure(
                    exitCode: 1,
                    stderr: "write_stdin target live MSP exec session \(sessionID) stdin write failed: \(error)\n"
                ),
                runningSessionID: sessionID
            )
        }
    }

    private func outputStream(
        sessionID: Int,
        stream: MSPExecCommandOutputStreamName,
        outputDispatcher: ModelShellProxyExecCommandOutputDispatcher
    ) -> any MSPCommandOutputStream {
        MSPClosureOutputStream { data in
            guard !data.isEmpty else {
                return
            }
            await self.append(data, sessionID: sessionID, stream: stream)
            let text = String(decoding: data, as: UTF8.self)
            guard !text.isEmpty else {
                return
            }
            await outputDispatcher.enqueue(MSPExecCommandOutputEvent(stream: stream, text: text))
        }
    }

    private func append(
        _ data: Data,
        sessionID: Int,
        stream: MSPExecCommandOutputStreamName
    ) {
        guard var session = sessions[sessionID] else {
            return
        }
        switch stream {
        case .stdout:
            session.stdoutBuffer.append(data)
            session.capturedStdoutStreamOutput = true
        case .stderr:
            session.stderrBuffer.append(data)
            session.capturedStderrStreamOutput = true
        }
        sessions[sessionID] = session
    }

    private func finish(sessionID: Int, result: MSPCommandResult) async {
        guard var session = sessions[sessionID], !session.terminated else {
            return
        }
        await session.stdinPipe.closeWrite()
        await session.stdinPipe.closeRead()
        if !session.capturedStdoutStreamOutput, !result.stdoutData.isEmpty {
            session.stdoutBuffer.append(result.stdoutData)
        }
        if !session.capturedStderrStreamOutput, !result.stderrData.isEmpty {
            session.stderrBuffer.append(result.stderrData)
        }
        session.completedResult = result
        sessions[sessionID] = session
    }

    private func waitForCompletionOrDeadline(
        sessionID: Int,
        milliseconds: Int
    ) async {
        let deadline = Date().addingTimeInterval(TimeInterval(max(0, milliseconds)) / 1000)
        while Date() < deadline {
            guard let session = sessions[sessionID] else {
                return
            }
            if session.completedResult != nil {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func consumeRead(sessionID: Int) -> MSPExecCommandSessionRead {
        guard var session = sessions[sessionID] else {
            return inactiveRead(sessionID: sessionID, operation: "read")
        }

        let stdout = session.stdoutBuffer.drain()
        let stderr = session.stderrBuffer.drain()

        if let completedResult = session.completedResult {
            sessions.removeValue(forKey: sessionID)
            return MSPExecCommandSessionRead(
                result: MSPCommandResult(
                    stdoutData: stdout,
                    stderrData: stderr,
                    exitCode: completedResult.exitCode,
                    stateChange: completedResult.stateChange,
                    modelContentItems: completedResult.modelContentItems
                ),
                wallTimeSeconds: Date().timeIntervalSince(session.startedAt),
                exitCode: completedResult.exitCode
            )
        }

        sessions[sessionID] = session
        return MSPExecCommandSessionRead(
            result: MSPCommandResult(stdoutData: stdout, stderrData: stderr),
            wallTimeSeconds: Date().timeIntervalSince(session.startedAt),
            runningSessionID: sessionID
        )
    }

    private func inactiveRead(
        sessionID: Int,
        operation: String
    ) -> MSPExecCommandSessionRead {
        MSPExecCommandSessionRead(
            result: .failure(
                exitCode: 1,
                stderr: "\(operation) failed: inactive session \(sessionID)\n"
            ),
            exitCode: 1
        )
    }

}
