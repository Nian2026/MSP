import Foundation
import MSPCore
import MSPPythonRuntime

final class MSPCPythonLiveIO: @unchecked Sendable {
    private let standardInput: Data
    private let standardInputStream: (any MSPCommandInputStream)?
    private let standardOutputStream: (any MSPCommandOutputStream)?
    private let standardErrorStream: (any MSPCommandOutputStream)?
    private let stdinPipe: Pipe?
    private let stdoutPipe: Pipe?
    private let stderrPipe: Pipe?
    private let outputGroup = DispatchGroup()
    private var stdinTask: Task<Void, Never>?

    init(request: MSPPythonEmbeddedExecutionRequest) {
        self.standardInput = request.standardInput
        self.standardInputStream = request.standardInputStream
        self.standardOutputStream = request.standardOutputStream
        self.standardErrorStream = request.standardErrorStream
        self.stdinPipe = request.standardInputStream == nil ? nil : Pipe()
        self.stdoutPipe = request.standardOutputStream == nil ? nil : Pipe()
        self.stderrPipe = request.standardErrorStream == nil ? nil : Pipe()
    }

    var stdinFileDescriptor: Int32? {
        stdinPipe.map { Int32($0.fileHandleForReading.fileDescriptor) }
    }

    var stdoutFileDescriptor: Int32? {
        stdoutPipe.map { Int32($0.fileHandleForWriting.fileDescriptor) }
    }

    var stderrFileDescriptor: Int32? {
        stderrPipe.map { Int32($0.fileHandleForWriting.fileDescriptor) }
    }

    var hasStandardOutputStream: Bool {
        standardOutputStream != nil
    }

    var hasStandardErrorStream: Bool {
        standardErrorStream != nil
    }

    func start(outputSanitizer: MSPPythonOutputPathSanitizer) {
        startInputPump()
        if let stdoutPipe, let standardOutputStream {
            startOutputPump(
                readHandle: stdoutPipe.fileHandleForReading,
                outputStream: standardOutputStream,
                sanitizer: outputSanitizer
            )
        }
        if let stderrPipe, let standardErrorStream {
            startOutputPump(
                readHandle: stderrPipe.fileHandleForReading,
                outputStream: standardErrorStream,
                sanitizer: outputSanitizer
            )
        }
    }

    func finish() {
        closeStandardInputStreamReadSide()
        stdinTask?.cancel()
        try? stdinPipe?.fileHandleForWriting.close()
        try? stdinPipe?.fileHandleForReading.close()
        try? stdoutPipe?.fileHandleForWriting.close()
        try? stderrPipe?.fileHandleForWriting.close()
        _ = outputGroup.wait(timeout: .now() + 2)
        try? stdoutPipe?.fileHandleForReading.close()
        try? stderrPipe?.fileHandleForReading.close()
    }

    func suppressStreamedOutput(
        in result: MSPPythonEmbeddedExecutionResult
    ) -> MSPPythonEmbeddedExecutionResult {
        MSPPythonEmbeddedExecutionResult(
            stdoutData: hasStandardOutputStream ? Data() : result.stdoutData,
            stderrData: hasStandardErrorStream ? Data() : result.stderrData,
            exitCode: result.exitCode
        )
    }

    private func startInputPump() {
        guard let stdinPipe else {
            return
        }
        let writeHandle = stdinPipe.fileHandleForWriting
        let standardInput = standardInput
        let standardInputStream = standardInputStream
        stdinTask = Task {
            if standardInputStream == nil, !standardInput.isEmpty {
                writeHandle.write(standardInput)
            }
            if let standardInputStream {
                do {
                    while !Task.isCancelled,
                          let chunk = try await standardInputStream.read(maxBytes: 32 * 1024) {
                        if !chunk.isEmpty {
                            writeHandle.write(chunk)
                        }
                    }
                } catch {
                    // Closing stdin below lets embedded Python observe EOF.
                }
            }
            try? writeHandle.close()
        }
    }

    private func startOutputPump(
        readHandle: FileHandle,
        outputStream: any MSPCommandOutputStream,
        sanitizer: MSPPythonOutputPathSanitizer
    ) {
        outputGroup.enter()
        Task {
            var streamingSanitizer = MSPPythonStreamingOutputSanitizer(sanitizer: sanitizer)
            while !Task.isCancelled {
                let data = readHandle.availableData
                guard !data.isEmpty else {
                    break
                }
                let sanitized = streamingSanitizer.append(data)
                if !sanitized.isEmpty {
                    try? await outputStream.write(sanitized)
                }
            }
            let remaining = streamingSanitizer.flush()
            if !remaining.isEmpty {
                try? await outputStream.write(remaining)
            }
            outputGroup.leave()
        }
    }

    private func closeStandardInputStreamReadSide() {
        guard let standardInputStream else {
            return
        }
        let group = DispatchGroup()
        group.enter()
        Task {
            await standardInputStream.closeRead()
            group.leave()
        }
        _ = group.wait(timeout: .now() + 1)
    }
}
