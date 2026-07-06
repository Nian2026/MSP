import Foundation
import MSPCore

final class MSPPythonSubprocessSession: @unchecked Sendable {
    let id: String
    private let request: MSPPythonSubprocessRequest
    private let baseContext: MSPCommandContext
    private let runner: MSPCommandLineRunner
    private let runnerGate: MSPPythonSubprocessRunnerGate
    private let cancellationToken: MSPPythonSubprocessCancellationToken
    private let condition = NSCondition()
    private let stdinOperationLock = NSLock()
    private let stdinPipe = MSPAsyncBytePipe(maxBufferedChunks: 32)
    private var started = false
    private var completed = false
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutOffset = 0
    private var stderrOffset = 0
    private var stdoutReadClosed = false
    private var stderrReadClosed = false
    private var storedReturnCode: Int32?
    private var task: Task<Void, Never>?

    init(
        id: String,
        request: MSPPythonSubprocessRequest,
        baseContext: MSPCommandContext,
        runner: @escaping MSPCommandLineRunner,
        runnerGate: MSPPythonSubprocessRunnerGate,
        cancellationToken: MSPPythonSubprocessCancellationToken
    ) {
        self.id = id
        self.request = request
        self.baseContext = baseContext
        self.runner = runner
        self.runnerGate = runnerGate
        self.cancellationToken = cancellationToken
    }

    var isRunning: Bool {
        condition.withLock { !completed }
    }

    var returnCode: Int32? {
        condition.withLock { storedReturnCode }
    }

    func start() {
        condition.lock()
        guard !started else {
            condition.unlock()
            return
        }
        started = true
        condition.unlock()

        let task = Task { [weak self] in
            guard let self else {
                return
            }
            var context = baseContext
            context.currentDirectory = MSPWorkspacePathResolver.normalize(
                request.cwd ?? baseContext.currentDirectory,
                from: baseContext.currentDirectory
            )
            if let environment = request.environment {
                context.environment = environment
            }
            if let workspace = context.workspace {
                context.workspace = MSPPythonCancellableWorkspace(
                    base: MSPPythonImplicitDirectoryWorkspace(base: workspace),
                    cancellationToken: cancellationToken
                )
            }
            context.standardInput = request.stdinData
            context.standardInputClosed = false
            if request.stdinPipe == true {
                context.standardInputStream = stdinPipe
            } else {
                context.standardInputStream = nil
                await stdinPipe.closeWrite()
            }
            let stdoutStream = MSPPythonSubprocessOutputStream(session: self, stream: "stdout")
            context.standardOutputStream = stdoutStream
            context.standardErrorStream = request.mergeStderrToStdout == true
                ? stdoutStream
                : MSPPythonSubprocessOutputStream(session: self, stream: "stderr")
            let commandLine = self.request.commandLine ?? ""
            let commandContext = context
            let runner = self.runner
            let cancellationToken = self.cancellationToken
            let result = await runnerGate.run {
                guard !cancellationToken.isCancelled, !Task.isCancelled else {
                    return MSPCommandResult(stdoutData: Data(), stderrData: Data(), exitCode: -15)
                }
                return await runner(commandLine, commandContext)
            }
            if Task.isCancelled {
                complete(returnCode: -15)
            } else {
                appendResultOutput(result)
                complete(returnCode: result.exitCode)
            }
        }
        condition.withLock {
            self.task = task
        }
    }

    func writeStdin(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        performStdinOperation {
            try? await self.stdinPipe.write(data)
        }
    }

    func closeStdin() {
        performStdinOperation {
            await self.stdinPipe.closeWrite()
        }
    }

    func appendOutput(stream: String, data: Data) throws {
        guard !data.isEmpty else {
            return
        }
        let isStderr = stream == "stderr"
        condition.lock()
        if outputReadClosed(isStderr: isStderr) {
            condition.unlock()
            markBrokenPipe()
            throw MSPCommandStreamError.brokenPipe
        }
        guard !completed, !cancellationToken.isCancelled else {
            condition.unlock()
            return
        }
        if isStderr {
            stderr.append(data)
        } else {
            stdout.append(data)
        }
        condition.broadcast()
        condition.unlock()
    }

    func appendResultOutput(_ result: MSPCommandResult) {
        condition.lock()
        guard !completed, !cancellationToken.isCancelled else {
            condition.unlock()
            return
        }
        let stdoutWouldWrite = !result.stdoutData.isEmpty
            || (request.mergeStderrToStdout == true && !result.stderrData.isEmpty)
        let brokenStdout = stdoutReadClosed && stdoutWouldWrite
        let brokenStderr = request.mergeStderrToStdout != true && stderrReadClosed && !result.stderrData.isEmpty
        if brokenStdout || brokenStderr {
            storedReturnCode = -13
            completed = true
            condition.broadcast()
            condition.unlock()
            cancellationToken.cancel()
            closeStdinPipeAsync()
            return
        }
        if request.mergeStderrToStdout == true {
            if stdout.isEmpty {
                stdout.append(result.stdoutData)
                stdout.append(result.stderrData)
            }
        } else {
            if stdout.isEmpty {
                stdout.append(result.stdoutData)
            }
            if stderr.isEmpty {
                stderr.append(result.stderrData)
            }
        }
        condition.broadcast()
        condition.unlock()
    }

    func complete(returnCode: Int32) {
        condition.lock()
        guard !completed else {
            condition.unlock()
            return
        }
        storedReturnCode = returnCode
        completed = true
        condition.broadcast()
        condition.unlock()
        closeStdinPipeAsync()
    }

    func wait(timeout: TimeInterval?) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if completed {
            return true
        }
        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while !completed {
                if !condition.wait(until: deadline) {
                    return completed
                }
            }
            return true
        }
        while !completed {
            condition.wait()
        }
        return true
    }

    func read(stream: String, maxBytes: Int) -> Data {
        condition.lock()
        defer { condition.unlock() }
        let isStderr = stream == "stderr"
        if outputReadClosed(isStderr: isStderr) {
            return Data()
        }
        if maxBytes < 0 {
            while !completed, !outputReadClosed(isStderr: isStderr) {
                condition.wait()
            }
        } else if maxBytes > 0 {
            while availableBytes(isStderr: isStderr) == 0,
                  !completed,
                  !outputReadClosed(isStderr: isStderr) {
                condition.wait()
            }
        }
        if outputReadClosed(isStderr: isStderr) {
            return Data()
        }
        let data = isStderr ? stderr : stdout
        let offset = isStderr ? stderrOffset : stdoutOffset
        let remaining = max(0, data.count - offset)
        let count = maxBytes < 0 ? remaining : min(maxBytes, remaining)
        guard count > 0 else {
            return Data()
        }
        let chunk = data.subdata(in: offset..<(offset + count))
        if isStderr {
            stderrOffset += count
        } else {
            stdoutOffset += count
        }
        return chunk
    }

    func unreadOutput(stream: String) -> Data {
        condition.withLock {
            guard !outputReadClosed(isStderr: stream == "stderr") else {
                return Data()
            }
            let data = stream == "stderr" ? stderr : stdout
            let offset = stream == "stderr" ? stderrOffset : stdoutOffset
            guard offset < data.count else {
                return Data()
            }
            return data.subdata(in: offset..<data.count)
        }
    }

    func kill(returnCode: Int32) {
        cancellationToken.cancel()
        let task = condition.withLock { self.task }
        task?.cancel()
        complete(returnCode: returnCode)
    }

    func closeOutputRead(stream: String) {
        condition.lock()
        if stream == "stderr" {
            stderrReadClosed = true
            stderr.removeAll(keepingCapacity: false)
            stderrOffset = 0
        } else {
            stdoutReadClosed = true
            stdout.removeAll(keepingCapacity: false)
            stdoutOffset = 0
        }
        condition.broadcast()
        condition.unlock()
    }

    private func markBrokenPipe() {
        cancellationToken.cancel()
        let taskToCancel: Task<Void, Never>?
        let shouldCloseStdin: Bool
        condition.lock()
        if completed {
            taskToCancel = nil
            shouldCloseStdin = false
        } else {
            storedReturnCode = -13
            completed = true
            taskToCancel = task
            shouldCloseStdin = true
            condition.broadcast()
        }
        condition.unlock()
        taskToCancel?.cancel()
        if shouldCloseStdin {
            closeStdinPipeAsync()
        }
    }

    private func availableBytes(isStderr: Bool) -> Int {
        if isStderr {
            return max(0, stderr.count - stderrOffset)
        }
        return max(0, stdout.count - stdoutOffset)
    }

    private func outputReadClosed(isStderr: Bool) -> Bool {
        isStderr ? stderrReadClosed : stdoutReadClosed
    }

    private func closeStdinPipeAsync() {
        Task {
            await stdinPipe.closeRead()
            await stdinPipe.closeWrite()
        }
    }

    private func performStdinOperation(_ operation: @escaping @Sendable () async -> Void) {
        stdinOperationLock.lock()
        defer { stdinOperationLock.unlock() }

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await operation()
            semaphore.signal()
        }
        semaphore.wait()
    }
}

private final class MSPPythonSubprocessOutputStream: MSPCommandOutputStream {
    private let session: MSPPythonSubprocessSession
    private let stream: String

    init(session: MSPPythonSubprocessSession, stream: String) {
        self.session = session
        self.stream = stream
    }

    func write(_ data: Data) async throws {
        try session.appendOutput(stream: stream, data: data)
    }

    func closeWrite() async {}
}

private extension NSCondition {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
