import Foundation
import MSPCore

protocol FindOutputWriter: AnyObject, Sendable {
    var stdoutData: Data { get async }
    var stderr: String { get async }

    func appendStdout(_ data: Data) async throws
    func appendStdout(_ text: String) async throws
    func appendStderr(_ data: Data) async throws
    func appendStderr(_ text: String) async throws
    func appendDiagnostic(_ message: String) async throws
    func flush() async throws
}

final class FindBufferedOutputWriter: FindOutputWriter {
    private let stdoutBuffer = MSPCommandOutputBuffer()
    private let stderrBuffer = MSPCommandOutputBuffer()

    var stdoutData: Data {
        get async { await stdoutBuffer.data() }
    }

    var stderr: String {
        get async { String(decoding: await stderrBuffer.data(), as: UTF8.self) }
    }

    func appendStdout(_ data: Data) async throws {
        try await stdoutBuffer.write(data)
    }

    func appendStdout(_ text: String) async throws {
        try await stdoutBuffer.write(Data(text.utf8))
    }

    func appendStderr(_ data: Data) async throws {
        try await stderrBuffer.write(data)
    }

    func appendStderr(_ text: String) async throws {
        try await stderrBuffer.write(Data(text.utf8))
    }

    func appendDiagnostic(_ message: String) async throws {
        guard !message.isEmpty else {
            return
        }
        let current = await stderr
        if current.isEmpty || current.hasSuffix("\n") || message.hasPrefix("\n") {
            try await appendStderr(message)
        } else {
            try await appendStderr("\n" + message)
        }
        if !(await stderr).hasSuffix("\n") {
            try await appendStderr("\n")
        }
    }

    func flush() async throws {}
}

final class FindStreamingOutputWriter: FindOutputWriter {
    private let stdoutBuffer = FindStreamingStdoutBuffer()
    private let standardOutput: any MSPCommandOutputStream
    private let standardError: any MSPCommandOutputStream
    private let stderrBuffer = MSPCommandOutputBuffer()

    init(standardOutput: any MSPCommandOutputStream, standardError: any MSPCommandOutputStream) {
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    var stdoutData: Data {
        get async { Data() }
    }

    var stderr: String {
        get async { String(decoding: await stderrBuffer.data(), as: UTF8.self) }
    }

    func appendStdout(_ data: Data) async throws {
        try await stdoutBuffer.write(data, to: standardOutput)
    }

    func appendStdout(_ text: String) async throws {
        try await appendStdout(Data(text.utf8))
    }

    func appendStderr(_ data: Data) async throws {
        try await stderrBuffer.write(data)
        try await standardError.write(data)
    }

    func appendStderr(_ text: String) async throws {
        try await appendStderr(Data(text.utf8))
    }

    func appendDiagnostic(_ message: String) async throws {
        guard !message.isEmpty else {
            return
        }
        let current = await stderr
        if current.isEmpty || current.hasSuffix("\n") || message.hasPrefix("\n") {
            try await appendStderr(message)
        } else {
            try await appendStderr("\n" + message)
        }
        if !(await stderr).hasSuffix("\n") {
            try await appendStderr("\n")
        }
    }

    func flush() async throws {
        try await stdoutBuffer.flush(to: standardOutput)
    }
}

private actor FindStreamingStdoutBuffer {
    private let flushThreshold: Int
    private var buffer = Data()

    init(flushThreshold: Int = 32 * 1024) {
        self.flushThreshold = max(1, flushThreshold)
    }

    func write(_ data: Data, to output: any MSPCommandOutputStream) async throws {
        guard !data.isEmpty else {
            return
        }
        buffer.append(data)
        if buffer.count >= flushThreshold {
            try await flush(to: output)
        }
    }

    func flush(to output: any MSPCommandOutputStream) async throws {
        guard !buffer.isEmpty else {
            return
        }
        let chunk = buffer
        buffer.removeAll(keepingCapacity: true)
        try await output.write(chunk)
    }
}
