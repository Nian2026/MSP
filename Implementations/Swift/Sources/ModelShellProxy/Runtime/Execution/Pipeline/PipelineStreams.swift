import Foundation
import MSPCore

enum ShellPipelineStreams {
    static let brokenPipeExitCode: Int32 = 128 + 13

    static func makeOutputStream(
        for binding: MSPRedirectionOutputBinding,
        defaultStdout: any MSPCommandOutputStream,
        defaultStderr: any MSPCommandOutputStream,
        closedReason: String,
        fileOutputs: inout [MSPStreamingPipelineFileOutput],
        fileOutputStream: (MSPRedirectionFileSink) -> (any MSPCommandOutputStream)?
    ) -> any MSPCommandOutputStream {
        switch binding {
        case .agentStdout:
            return defaultStdout
        case .agentStderr:
            return defaultStderr
        case .closed:
            return MSPClosedOutputStream(reason: closedReason)
        case .discard:
            return MSPBlackHoleOutputStream()
        case .file(let sink):
            if let stream = fileOutputStream(sink) {
                return stream
            }
            let output = MSPStreamingPipelineFileOutput(binding: binding)
            fileOutputs.append(output)
            return output.buffer
        case .openFileDescription:
            let output = MSPStreamingPipelineFileOutput(binding: binding)
            fileOutputs.append(output)
            return output.buffer
        }
    }
}

final class MSPStreamingPipelinePipe: MSPCommandInputStream, MSPCommandOutputStream {
    private let pipe: MSPAsyncBytePipe
    private let state = MSPStreamingPipelinePipeState()

    init(maxBufferedChunks: Int = 32) {
        self.pipe = MSPAsyncBytePipe(maxBufferedChunks: maxBufferedChunks)
    }

    func read(maxBytes: Int) async throws -> Data? {
        try await pipe.read(maxBytes: maxBytes)
    }

    func write(_ data: Data) async throws {
        do {
            try await pipe.write(data)
        } catch MSPCommandStreamError.brokenPipe {
            await state.markBrokenPipe()
            throw MSPCommandStreamError.brokenPipe
        }
    }

    func closeRead() async {
        await pipe.closeRead()
    }

    func closeWrite() async {
        await pipe.closeWrite()
    }

    var didBreakOnWrite: Bool {
        get async { await state.didBreakOnWrite }
    }
}

private actor MSPStreamingPipelinePipeState {
    private(set) var didBreakOnWrite = false

    func markBrokenPipe() {
        didBreakOnWrite = true
    }
}
