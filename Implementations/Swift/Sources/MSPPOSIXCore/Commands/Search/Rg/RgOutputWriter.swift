import Foundation
import MSPCore

protocol RgOutputWriter: AnyObject, Sendable {
    var stdoutData: Data { get async }
    var stderr: String { get async }

    func appendStdout(_ text: String) async throws
    func appendStdoutLine(_ line: String) async throws
    func appendDiagnostic(_ message: String) async throws
}

final class RgBufferedOutputWriter: RgOutputWriter {
    private let stdoutBuffer = MSPCommandOutputBuffer()
    private let stderrBuffer = MSPCommandOutputBuffer()

    var stdoutData: Data {
        get async { await stdoutBuffer.data() }
    }

    var stderr: String {
        get async { String(decoding: await stderrBuffer.data(), as: UTF8.self) }
    }

    func appendStdout(_ text: String) async throws {
        try await stdoutBuffer.write(Data(text.utf8))
    }

    func appendStdoutLine(_ line: String) async throws {
        try await appendStdout(line + "\n")
    }

    func appendDiagnostic(_ message: String) async throws {
        guard !message.isEmpty else {
            return
        }
        let current = await stderr
        if !current.isEmpty, !current.hasSuffix("\n"), !message.hasPrefix("\n") {
            try await stderrBuffer.write(Data("\n".utf8))
        }
        try await stderrBuffer.write(Data(message.utf8))
        if !(await stderr).hasSuffix("\n") {
            try await stderrBuffer.write(Data("\n".utf8))
        }
    }
}

final class RgStreamingOutputWriter: RgOutputWriter {
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

    func appendStdout(_ text: String) async throws {
        try await standardOutput.write(Data(text.utf8))
    }

    func appendStdoutLine(_ line: String) async throws {
        try await appendStdout(line + "\n")
    }

    func appendDiagnostic(_ message: String) async throws {
        guard !message.isEmpty else {
            return
        }
        let current = await stderr
        if !current.isEmpty, !current.hasSuffix("\n"), !message.hasPrefix("\n") {
            let newline = Data("\n".utf8)
            try await stderrBuffer.write(newline)
            try await standardError.write(newline)
        }
        let data = Data(message.utf8)
        try await stderrBuffer.write(data)
        try await standardError.write(data)
        if !(await stderr).hasSuffix("\n") {
            let newline = Data("\n".utf8)
            try await stderrBuffer.write(newline)
            try await standardError.write(newline)
        }
    }
}
