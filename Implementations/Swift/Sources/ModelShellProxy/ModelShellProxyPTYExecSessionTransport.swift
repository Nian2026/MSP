import Foundation
import MSPAgentBridge
import MSPCore
import MSPPtySupport

#if os(macOS) || (os(iOS) && targetEnvironment(simulator))
import Darwin

actor ModelShellProxyPTYExecSessionTransport: MSPExecCommandSessionTransport {
    static var isAvailable: Bool { true }

    private struct Session {
        var startedAt: Date
        var masterFD: Int32
        var processID: pid_t
        var outputBuffer = ModelShellProxySessionOutputBuffer()
        var suppressedOutputPrefix = Data()
        var outputDispatcher: ModelShellProxyExecCommandOutputDispatcher
        var outputClosed = false
        var exitCode: Int32?
        var signal: Int32?
        var readTask: Task<Void, Never>?
        var waitTask: Task<Void, Never>?
        var terminated = false

        var isComplete: Bool {
            outputClosed && (exitCode != nil || signal != nil)
        }
    }

    private var sessions: [Int: Session] = [:]

    func start(
        call: MSPExecCommandCall,
        sessionID: Int,
        onOutput: MSPExecCommandOutputHandler?
    ) async -> MSPExecCommandSessionRead {
        guard call.tty else {
            return MSPExecCommandSessionRead(
                result: .failure(exitCode: 1, stderr: "PTY backend received tty=false call\n"),
                exitCode: 1
            )
        }

        let startedAt = Date()
        do {
            let spawned = try ModelShellProxyPTYProcessSupport.spawnPTYProcess(call: call)
            try ModelShellProxyPTYProcessSupport.configureNonBlocking(masterFD: spawned.masterFD)
            let outputDispatcher = ModelShellProxyExecCommandOutputDispatcher(
                outputHandler: onOutput
            )
            sessions[sessionID] = Session(
                startedAt: startedAt,
                masterFD: spawned.masterFD,
                processID: spawned.processID,
                outputDispatcher: outputDispatcher
            )
            let readTask = Task.detached(priority: .userInitiated) { [weak self] in
                guard let transport = self else {
                    return
                }
                await Self.readOutput(
                    masterFD: spawned.masterFD,
                    sessionID: sessionID,
                    outputDispatcher: outputDispatcher,
                    transport: transport
                )
            }
            let waitTask = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else {
                    return
                }
                var status: Int32 = 0
                let waited = waitpid(spawned.processID, &status, 0)
                guard waited == spawned.processID else {
                    await self.markExited(
                        sessionID: sessionID,
                        status: ModelShellProxyPTYWaitStatus(exitCode: 1, signal: nil)
                    )
                    return
                }
                await self.markExited(
                    sessionID: sessionID,
                    status: ModelShellProxyPTYProcessSupport.decodeWaitStatus(status)
                )
            }
            sessions[sessionID]?.readTask = readTask
            sessions[sessionID]?.waitTask = waitTask
        } catch {
            return MSPExecCommandSessionRead(
                result: .failure(exitCode: 1, stderr: "exec_command PTY start failed: \(error.localizedDescription)\n"),
                wallTimeSeconds: Date().timeIntervalSince(startedAt),
                exitCode: 1
            )
        }

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
        guard var session = sessions[call.sessionID] else {
            return inactiveRead(sessionID: call.sessionID, operation: "write_stdin")
        }
        if session.isComplete {
            return consumeRead(sessionID: call.sessionID)
        }

        var terminalModeSnapshot = MSPPtyTerminalModeSnapshot()
        var didEnterNoncanonicalMode = false
        let stdinBytes = call.stdinBytes
        if !stdinBytes.isEmpty {
            let bytes = Array(stdinBytes)
            if bytes.contains(4) {
                session.suppressedOutputPrefix.append(ModelShellProxyPTYCanonicalPaste.macOSEOFVisualEraseEcho)
                sessions[call.sessionID] = session
            }
            var data = stdinBytes
            let masterFD = session.masterFD
            let processID = session.processID
            if let plan = ModelShellProxyPTYCanonicalPaste.plan(for: stdinBytes),
               msp_pty_enter_noncanonical_noecho_mode(masterFD, &terminalModeSnapshot) == 0 {
                if terminalModeSnapshot.was_canonical != 0 {
                    didEnterNoncanonicalMode = true
                    data = plan.forwardedInput
                    if terminalModeSnapshot.was_echoing != 0 {
                        session.suppressedOutputPrefix.append(plan.nativeEchoOutput)
                        session.outputBuffer.append(plan.echoOutput)
                        sessions[call.sessionID] = session
                        await Self.dispatchOutput(
                            plan.echoOutput,
                            outputDispatcher: session.outputDispatcher
                        )
                    }
                } else {
                    _ = msp_pty_restore_terminal_mode(masterFD, &terminalModeSnapshot)
                }
            }
            let wroteAll = await Task.detached(priority: .userInitiated) {
                ModelShellProxyPTYProcessSupport.writeAll(
                    data,
                    to: masterFD,
                    timeoutMilliseconds: ModelShellProxyPTYProcessSupport.writeTimeoutMilliseconds
                )
            }.value
            guard wroteAll else {
                if didEnterNoncanonicalMode {
                    _ = msp_pty_restore_terminal_mode(masterFD, &terminalModeSnapshot)
                }
                return MSPExecCommandSessionRead(
                    result: .failure(exitCode: 1, stderr: "write_stdin target live MSP PTY session \(call.sessionID) write failed.\n"),
                    runningSessionID: call.sessionID
                )
            }
            if bytes.contains(3) {
                _ = ModelShellProxyPTYProcessSupport.killProcessGroup(processID, signal: SIGINT)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        await waitForCompletionOrDeadline(
            sessionID: call.sessionID,
            milliseconds: MSPExecCommandYieldPolicy.writeStdinMilliseconds(
                call.yieldTimeMilliseconds,
                isEmpty: stdinBytes.isEmpty
            )
        )
        if didEnterNoncanonicalMode {
            _ = msp_pty_restore_terminal_mode(session.masterFD, &terminalModeSnapshot)
        }
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
        _ = ModelShellProxyPTYProcessSupport.killProcessGroup(session.processID, signal: SIGTERM)
        try? await Task.sleep(nanoseconds: 150_000_000)
        _ = ModelShellProxyPTYProcessSupport.killProcessGroup(session.processID, signal: SIGKILL)
        Darwin.close(session.masterFD)
        session.readTask?.cancel()
        session.waitTask?.cancel()

        let stdout = session.outputBuffer.drain()
        return MSPExecCommandSessionRead(
            result: .failure(
                exitCode: 143,
                stdoutData: stdout,
                stderr: "terminated\n"
            ),
            wallTimeSeconds: Date().timeIntervalSince(session.startedAt),
            exitCode: 143,
            signal: SIGTERM
        )
    }

    private static func readOutput(
        masterFD: Int32,
        sessionID: Int,
        outputDispatcher: ModelShellProxyExecCommandOutputDispatcher,
        transport: ModelShellProxyPTYExecSessionTransport
    ) async {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while !Task.isCancelled {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(masterFD, rawBuffer.baseAddress, rawBuffer.count)
            }
            if bytesRead > 0 {
                let data = Data(buffer.prefix(Int(bytesRead)))
                await transport.append(data, sessionID: sessionID, outputDispatcher: outputDispatcher)
            } else if bytesRead == 0 {
                break
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                ModelShellProxyPTYProcessSupport.waitUntilReadable(
                    fd: masterFD,
                    timeoutMilliseconds: 50
                )
                continue
            } else {
                break
            }
        }
        await transport.markOutputClosed(sessionID: sessionID)
    }

    private func append(
        _ data: Data,
        sessionID: Int,
        outputDispatcher: ModelShellProxyExecCommandOutputDispatcher
    ) async {
        guard var session = sessions[sessionID], !data.isEmpty else {
            return
        }
        var visibleData = data
        if !session.suppressedOutputPrefix.isEmpty {
            let filtered = ModelShellProxyPTYSuppressedOutput.removingSuppressedPrefix(
                session.suppressedOutputPrefix,
                from: visibleData
            )
            visibleData = filtered.visibleData
            session.suppressedOutputPrefix = filtered.remainingPrefix
        }
        guard !visibleData.isEmpty else {
            sessions[sessionID] = session
            return
        }
        session.outputBuffer.append(visibleData)
        sessions[sessionID] = session
        let text = String(decoding: visibleData, as: UTF8.self)
        guard !text.isEmpty else {
            return
        }
        await outputDispatcher.enqueue(MSPExecCommandOutputEvent(stream: .stdout, text: text))
    }

    private static func dispatchOutput(
        _ data: Data,
        outputDispatcher: ModelShellProxyExecCommandOutputDispatcher
    ) async {
        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else {
            return
        }
        await outputDispatcher.enqueue(MSPExecCommandOutputEvent(stream: .stdout, text: text))
    }

    private func markOutputClosed(sessionID: Int) {
        guard var session = sessions[sessionID] else {
            return
        }
        session.outputClosed = true
        sessions[sessionID] = session
    }

    private func markExited(
        sessionID: Int,
        status: ModelShellProxyPTYWaitStatus
    ) {
        guard var session = sessions[sessionID] else {
            return
        }
        session.exitCode = status.exitCode
        session.signal = status.signal
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
            if session.isComplete {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func consumeRead(sessionID: Int) -> MSPExecCommandSessionRead {
        guard var session = sessions[sessionID] else {
            return inactiveRead(sessionID: sessionID, operation: "read")
        }

        let stdout = session.outputBuffer.drain()

        if session.isComplete {
            sessions.removeValue(forKey: sessionID)
            Darwin.close(session.masterFD)
            let resultExitCode = session.exitCode ?? session.signal.map { 128 + $0 } ?? 0
            return MSPExecCommandSessionRead(
                result: MSPCommandResult(
                    stdoutData: stdout,
                    stderrData: Data(),
                    exitCode: resultExitCode
                ),
                wallTimeSeconds: Date().timeIntervalSince(session.startedAt),
                exitCode: session.exitCode,
                signal: session.signal
            )
        }

        sessions[sessionID] = session
        return MSPExecCommandSessionRead(
            result: MSPCommandResult(stdoutData: stdout, stderrData: Data()),
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
                stderr: "\(operation) failed: inactive PTY session \(sessionID)\n"
            ),
            exitCode: 1
        )
    }

}

#endif
