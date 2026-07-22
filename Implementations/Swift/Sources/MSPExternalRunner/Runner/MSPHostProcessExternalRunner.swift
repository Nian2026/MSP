#if os(macOS) || os(Linux)
import Foundation
import MSPCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public struct MSPHostProcessExternalRunner: MSPExternalCommandRunner {
    public var executableURL: URL
    public var timeout: TimeInterval
    public var extraEnvironment: [String: String]
    public var versionOutput: String?

    public init(
        executableURL: URL,
        timeout: TimeInterval = 30,
        extraEnvironment: [String: String] = [:],
        versionOutput: String? = nil
    ) {
        self.executableURL = executableURL
        self.timeout = timeout
        self.extraEnvironment = extraEnvironment
        self.versionOutput = versionOutput
    }

    public func run(
        _ request: MSPExternalCommandRequest,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        let pathMapper = MSPExternalCommandPathMapper(executableURL: executableURL)
        if let versionOutput,
           request.arguments.count == 1,
           (request.arguments[0] == "--version" || request.arguments[0] == "-v") {
            guard context.workspace != nil else {
                return .success(stdout: versionOutput)
            }
            return try pathMapper.outputSanitizer(context: context)
                .sanitize(.success(stdout: versionOutput))
        }
        let workingDirectoryURL = try pathMapper.workingDirectoryURL(
            virtualPath: request.workingDirectory,
            context: context
        )
        let standardInput = try await bufferedStandardInput(from: context)
        let outputSanitizer = try pathMapper.outputSanitizer(context: context)
        return try runProcess(
            request: request,
            context: context,
            pathMapper: pathMapper,
            workingDirectoryURL: workingDirectoryURL,
            standardInput: standardInput,
            outputSanitizer: outputSanitizer
        )
    }

    private func bufferedStandardInput(from context: MSPCommandContext) async throws -> Data {
        guard let stream = context.standardInputStream else {
            return context.standardInput
        }
        var data = Data()
        while let chunk = try await stream.read(maxBytes: 32 * 1024) {
            data.append(chunk)
        }
        return data
    }

    private func runProcess(
        request: MSPExternalCommandRequest,
        context: MSPCommandContext,
        pathMapper: MSPExternalCommandPathMapper,
        workingDirectoryURL: URL,
        standardInput: Data,
        outputSanitizer: MSPOutputPathSanitizer
    ) throws -> MSPCommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = try pathMapper.arguments(request.arguments, context: context)
        process.currentDirectoryURL = workingDirectoryURL
        process.environment = try pathMapper.environment(
            request: request,
            extraEnvironment: extraEnvironment,
            context: context
        )

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        let stdoutBuffer = MSPHostProcessLockedDataBuffer()
        let stderrBuffer = MSPHostProcessLockedDataBuffer()
        let outputStopSignal = MSPHostProcessOutputStopSignal()
        let outputReadGroup = DispatchGroup()
        let outputReadQueue = DispatchQueue(
            label: "dev.modelshellproxy.external-runner-output",
            attributes: .concurrent
        )

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            return MSPCommandResult(
                stdout: "",
                stderr: launchFailureStderr(
                    request: request,
                    error: error,
                    outputSanitizer: outputSanitizer
                ),
                exitCode: 126
            )
        }

        readOutput(
            from: stdoutPipe,
            into: stdoutBuffer,
            stopSignal: outputStopSignal,
            group: outputReadGroup,
            queue: outputReadQueue
        )
        readOutput(
            from: stderrPipe,
            into: stderrBuffer,
            stopSignal: outputStopSignal,
            group: outputReadGroup,
            queue: outputReadQueue
        )

        if !standardInput.isEmpty {
            stdinPipe.fileHandleForWriting.write(standardInput)
        }
        try? stdinPipe.fileHandleForWriting.close()

        let timedOut = semaphore.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 1)
        }
        process.terminationHandler = nil
        outputStopSignal.stop()
        outputReadGroup.wait()

        var stderr = stderrBuffer.data()
        if timedOut {
            stderr.append(Data("\(request.executableName): timed out after \(Int(timeout))s\n".utf8))
        }

        return outputSanitizer.sanitize(MSPCommandResult(
            stdoutData: stdoutBuffer.data(),
            stderrData: stderr,
            exitCode: timedOut ? 124 : process.terminationStatus
        ))
    }

    private func readOutput(
        from pipe: Pipe,
        into buffer: MSPHostProcessLockedDataBuffer,
        stopSignal: MSPHostProcessOutputStopSignal,
        group: DispatchGroup,
        queue: DispatchQueue
    ) {
        group.enter()
        queue.async {
            readPipeOutput(pipe.fileHandleForReading, into: buffer, stopSignal: stopSignal)
            try? pipe.fileHandleForReading.close()
            group.leave()
        }
    }

    private func readPipeOutput(
        _ fileHandle: FileHandle,
        into buffer: MSPHostProcessLockedDataBuffer,
        stopSignal: MSPHostProcessOutputStopSignal
    ) {
        let fd = fileHandle.fileDescriptor
        setNonBlocking(fd)
        var scratch = [UInt8](repeating: 0, count: 32 * 1024)
        var stopDrainDeadline: Date?

        while true {
            if stopSignal.isStopped {
                if let deadline = stopDrainDeadline {
                    if Date() >= deadline {
                        return
                    }
                } else {
                    stopDrainDeadline = Date().addingTimeInterval(0.2)
                }
            }

            let count = scratch.withUnsafeMutableBytes { pointer in
                read(fd, pointer.baseAddress, pointer.count)
            }
            if count > 0 {
                buffer.append(Data(scratch.prefix(Int(count))))
                continue
            }
            if count == 0 {
                return
            }

            let error = errno
            if error == EINTR {
                continue
            }
            guard isWouldBlock(error) else {
                return
            }

            if stopSignal.isStopped {
                if stopDrainDeadline == nil {
                    stopDrainDeadline = Date().addingTimeInterval(0.2)
                } else if Date() >= stopDrainDeadline! {
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else {
            return
        }
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    private func isWouldBlock(_ error: Int32) -> Bool {
        error == EAGAIN || error == EWOULDBLOCK
    }

    private func launchFailureStderr(
        request: MSPExternalCommandRequest,
        error: Error,
        outputSanitizer: MSPOutputPathSanitizer
    ) -> String {
        let modelExecutablePath = modelVisibleExecutablePath(outputSanitizer: outputSanitizer)
        let reason = launchFailureReason(error, outputSanitizer: outputSanitizer)
        return "\(request.executableName): failed to start \(modelExecutablePath): \(reason)\n"
    }

    private func modelVisibleExecutablePath(
        outputSanitizer: MSPOutputPathSanitizer
    ) -> String {
        let hostPath = executableURL.path
        let sanitizedPath = outputSanitizer.sanitize(hostPath)
        guard sanitizedPath != hostPath else {
            return executableURL.lastPathComponent
        }
        return sanitizedPath
    }

    private func launchFailureReason(
        _ error: Error,
        outputSanitizer: MSPOutputPathSanitizer
    ) -> String {
        let sanitizedDescription = outputSanitizer.sanitize((error as NSError).localizedDescription)
        guard !sanitizedDescription.contains("/") else {
            return "process could not be started"
        }
        return sanitizedDescription
    }

}

public typealias MSPHostProcessExternalRunnerError = MSPExternalCommandPathMapperError

private final class MSPHostProcessLockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    func data() -> Data {
        lock.lock()
        let snapshot = storage
        lock.unlock()
        return snapshot
    }
}

private final class MSPHostProcessOutputStopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isStopped: Bool {
        lock.lock()
        let value = stopped
        lock.unlock()
        return value
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}
#endif
