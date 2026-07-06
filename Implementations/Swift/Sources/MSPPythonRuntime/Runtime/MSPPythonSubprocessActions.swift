import Foundation
import MSPCore

extension MSPPythonSubprocessBroker {
    func handle(_ request: MSPPythonSubprocessRequest) -> MSPPythonSubprocessResponse {
        switch request.action ?? "run" {
        case "run":
            return run(request)
        case "start":
            return startSession(request)
        case "read":
            return read(request)
        case "write":
            return writeStdin(request)
        case "closeStdin", "close_stdin":
            return closeStdin(request)
        case "closeOutput", "close_output", "closeStdout", "close_stdout", "closeStderr", "close_stderr":
            return closeOutput(request)
        case "poll":
            return poll(request)
        case "wait":
            return wait(request)
        case "kill":
            return kill(request, returnCode: -9)
        case "terminate":
            return kill(request, returnCode: -15)
        case "signal", "sendSignal", "send_signal":
            return signal(request)
        case "close":
            return close(request)
        default:
            return .failure(stderr: "subprocess: unsupported broker action \(request.action ?? "")\n")
        }
    }

    func run(_ request: MSPPythonSubprocessRequest) -> MSPPythonSubprocessResponse {
        guard let runner else {
            return .failure(stderr: "subprocess: MSP command runner is unavailable\n", exitCode: 125)
        }
        let resultBox = MSPPythonSubprocessResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        let stdoutBuffer = MSPCommandOutputBuffer()
        let stderrBuffer = request.mergeStderrToStdout == true ? stdoutBuffer : MSPCommandOutputBuffer()
        let cancellationToken = MSPPythonSubprocessCancellationToken()
        let timeout = request.remainingTimeout
        if request.timeout != nil, timeout == nil || timeout == 0 {
            cancellationToken.cancel()
            return .timedOut()
        }
        let task = Task {
            defer {
                semaphore.signal()
            }
            var context = context(
                for: request,
                stdinData: request.stdinData,
                cancellationToken: cancellationToken
            )
            context.standardOutputStream = stdoutBuffer
            context.standardErrorStream = stderrBuffer
            let commandLine = request.commandLine ?? ""
            let commandContext = context
            let result = await runnerGate.run {
                guard !cancellationToken.isCancelled, !Task.isCancelled else {
                    return MSPCommandResult(stdoutData: Data(), stderrData: Data(), exitCode: -15)
                }
                return await runner(commandLine, commandContext)
            }
            guard !cancellationToken.isCancelled else {
                return
            }
            if request.mergeStderrToStdout == true {
                var stdoutData = await stdoutBuffer.data()
                if stdoutData.isEmpty {
                    stdoutData.append(result.stdoutData)
                    stdoutData.append(result.stderrData)
                }
                resultBox.set(MSPCommandResult(stdoutData: stdoutData, exitCode: result.exitCode))
            } else {
                var stdoutData = await stdoutBuffer.data()
                var stderrData = await stderrBuffer.data()
                if stdoutData.isEmpty {
                    stdoutData.append(result.stdoutData)
                }
                if stderrData.isEmpty {
                    stderrData.append(result.stderrData)
                }
                resultBox.set(MSPCommandResult(
                    stdoutData: stdoutData,
                    stderrData: stderrData,
                    exitCode: result.exitCode
                ))
            }
        }

        if let timeout,
           semaphore.wait(timeout: .now() + timeout) == .timedOut {
            let stdoutData = bufferedData(stdoutBuffer)
            let stderrData = request.mergeStderrToStdout == true
                ? Data()
                : bufferedData(stderrBuffer)
            cancellationToken.cancel()
            task.cancel()
            return .timedOut(
                stdoutB64: stdoutData.base64EncodedString(),
                stderrB64: stderrData.base64EncodedString()
            )
        }
        if request.timeout == nil {
            semaphore.wait()
        }

        let result = resultBox.result ?? .failure(
            exitCode: 125,
            stderr: "subprocess: MSP command runner did not return\n"
        )
        return MSPPythonSubprocessResponse(result: result)
    }

    func startSession(_ request: MSPPythonSubprocessRequest) -> MSPPythonSubprocessResponse {
        guard let runner else {
            return .failure(stderr: "subprocess: MSP command runner is unavailable\n", exitCode: 125)
        }
        let id = UUID().uuidString
        let session = MSPPythonSubprocessSession(
            id: id,
            request: request,
            baseContext: baseContext,
            runner: runner,
            runnerGate: runnerGate,
            cancellationToken: MSPPythonSubprocessCancellationToken()
        )
        lock.withLock {
            sessions[id] = session
        }
        session.start()
        return .success(sessionID: id, running: true)
    }

    func read(_ request: MSPPythonSubprocessRequest) -> MSPPythonSubprocessResponse {
        guard let session = session(for: request) else {
            return .failure(stderr: "subprocess: missing session\n")
        }
        let data = session.read(
            stream: request.stream ?? "stdout",
            maxBytes: request.maxBytes ?? -1
        )
        return .success(
            exitCode: session.returnCode ?? 0,
            dataB64: data.base64EncodedString(),
            running: session.isRunning
        )
    }

    func writeStdin(_ request: MSPPythonSubprocessRequest) -> MSPPythonSubprocessResponse {
        guard let session = session(for: request) else {
            return .failure(stderr: "subprocess: missing session\n")
        }
        session.writeStdin(request.stdinData)
        return .success(exitCode: session.returnCode ?? 0, running: session.isRunning)
    }

    func closeStdin(_ request: MSPPythonSubprocessRequest) -> MSPPythonSubprocessResponse {
        guard let session = session(for: request) else {
            return .failure(stderr: "subprocess: missing session\n")
        }
        session.closeStdin()
        return .success(exitCode: session.returnCode ?? 0, running: session.isRunning)
    }

    func closeOutput(_ request: MSPPythonSubprocessRequest) -> MSPPythonSubprocessResponse {
        guard let session = session(for: request) else {
            return .failure(stderr: "subprocess: missing session\n")
        }
        let stream = request.stream
            ?? (request.action?.localizedCaseInsensitiveContains("stderr") == true ? "stderr" : "stdout")
        session.closeOutputRead(stream: stream)
        return .success(exitCode: session.returnCode ?? 0, running: session.isRunning)
    }

    func poll(_ request: MSPPythonSubprocessRequest) -> MSPPythonSubprocessResponse {
        guard let session = session(for: request) else {
            return .failure(stderr: "subprocess: missing session\n")
        }
        let running = session.isRunning
        return .success(
            exitCode: session.returnCode ?? 0,
            stdoutB64: running ? "" : session.unreadOutput(stream: "stdout").base64EncodedString(),
            stderrB64: running ? "" : session.unreadOutput(stream: "stderr").base64EncodedString(),
            running: running
        )
    }

    func wait(_ request: MSPPythonSubprocessRequest) -> MSPPythonSubprocessResponse {
        guard let session = session(for: request) else {
            return .failure(stderr: "subprocess: missing session\n")
        }
        let timeout = request.remainingTimeout
        if request.timeout != nil, timeout == nil || timeout == 0 {
            return .timedOut(
                running: session.isRunning,
                stdoutB64: session.unreadOutput(stream: "stdout").base64EncodedString(),
                stderrB64: session.unreadOutput(stream: "stderr").base64EncodedString()
            )
        }
        guard session.wait(timeout: timeout) else {
            return .timedOut(
                running: true,
                stdoutB64: session.unreadOutput(stream: "stdout").base64EncodedString(),
                stderrB64: session.unreadOutput(stream: "stderr").base64EncodedString()
            )
        }
        return .success(
            exitCode: session.returnCode ?? 0,
            stdoutB64: session.unreadOutput(stream: "stdout").base64EncodedString(),
            stderrB64: session.unreadOutput(stream: "stderr").base64EncodedString(),
            running: false
        )
    }

    func kill(_ request: MSPPythonSubprocessRequest, returnCode: Int32) -> MSPPythonSubprocessResponse {
        guard let session = session(for: request) else {
            return .failure(stderr: "subprocess: missing session\n")
        }
        session.kill(returnCode: returnCode)
        return .success(exitCode: session.returnCode ?? returnCode, running: false)
    }

    func signal(_ request: MSPPythonSubprocessRequest) -> MSPPythonSubprocessResponse {
        guard let session = session(for: request) else {
            return .failure(stderr: "subprocess: missing session\n")
        }
        let signalNumber = request.signalNumber ?? 15
        guard signalNumber != 0 else {
            return .success(exitCode: session.returnCode ?? 0, running: session.isRunning)
        }
        let returnCode = -abs(signalNumber)
        session.kill(returnCode: returnCode)
        return .success(exitCode: session.returnCode ?? returnCode, running: false)
    }

    func close(_ request: MSPPythonSubprocessRequest) -> MSPPythonSubprocessResponse {
        guard let id = request.sessionID else {
            return .failure(stderr: "subprocess: missing session\n")
        }
        let session = lock.withLock {
            sessions.removeValue(forKey: id)
        }
        if session?.isRunning == true {
            session?.kill(returnCode: -15)
        }
        return .success(running: false)
    }
}

private final class MSPPythonSubprocessResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: MSPCommandResult?

    var result: MSPCommandResult? {
        lock.withLock { storedResult }
    }

    func set(_ result: MSPCommandResult) {
        lock.withLock {
            storedResult = result
        }
    }
}

private func bufferedData(_ buffer: MSPCommandOutputBuffer) -> Data {
    let box = MSPPythonSubprocessDataBox()
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let data = await buffer.data()
        box.set(data)
        semaphore.signal()
    }
    semaphore.wait()
    return box.data
}

private final class MSPPythonSubprocessDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedData = Data()

    var data: Data {
        lock.withLock { storedData }
    }

    func set(_ data: Data) {
        lock.withLock {
            storedData = data
        }
    }
}

private extension MSPPythonSubprocessResponse {
    init(result: MSPCommandResult) {
        self.init(
            stdoutB64: result.stdoutData.base64EncodedString(),
            stderrB64: result.stderrData.base64EncodedString(),
            exitCode: result.exitCode
        )
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
