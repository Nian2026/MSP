import Foundation

public enum MSPCommandStreamError: Error, Sendable, Equatable {
    case brokenPipe
    case writeError(String)
}

public protocol MSPCommandInputStream: Sendable {
    func read(maxBytes: Int) async throws -> Data?
    func closeRead() async
}

public extension MSPCommandInputStream {
    func closeRead() async {}
}

public protocol MSPCommandOutputStream: Sendable {
    func write(_ data: Data) async throws
    func closeWrite() async
}

public extension MSPCommandOutputStream {
    func closeWrite() async {}
}

public protocol MSPStreamingCommand: MSPCommand {
    func runStreaming(
        invocation: MSPCommandInvocation,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult
}

public final class MSPDataInputStream: MSPCommandInputStream {
    private let storage: MSPDataInputStreamStorage

    public init(_ data: Data) {
        self.storage = MSPDataInputStreamStorage(data: data)
    }

    public func read(maxBytes: Int) async throws -> Data? {
        await storage.read(maxBytes: maxBytes)
    }

    public func closeRead() async {
        await storage.closeRead()
    }
}

public final class MSPWorkspaceFileInputStream: MSPCommandInputStream {
    private let storage: MSPWorkspaceFileInputStreamStorage

    public init(
        fileSystem: any MSPWorkspaceFileSystem,
        path: String,
        currentDirectory: String,
        chunkSize: Int = 32 * 1024
    ) {
        self.storage = MSPWorkspaceFileInputStreamStorage(
            fileSystem: fileSystem,
            path: path,
            currentDirectory: currentDirectory,
            chunkSize: max(1, chunkSize)
        )
    }

    public func read(maxBytes: Int) async throws -> Data? {
        try await storage.read(maxBytes: maxBytes)
    }

    public func closeRead() async {
        await storage.closeRead()
    }
}

public final class MSPWorkspaceFileOutputStream: MSPCommandOutputStream {
    private let storage: MSPWorkspaceFileOutputStreamStorage

    public init(
        fileSystem: any MSPWorkspaceFileSystem,
        path: String,
        currentDirectory: String,
        creationMode: UInt16? = nil
    ) {
        self.storage = MSPWorkspaceFileOutputStreamStorage(
            fileSystem: fileSystem,
            path: path,
            currentDirectory: currentDirectory,
            creationMode: creationMode
        )
    }

    public func write(_ data: Data) async throws {
        try await storage.write(data)
    }

    public func closeWrite() async {
        await storage.closeWrite()
    }
}

private actor MSPWorkspaceFileOutputStreamStorage {
    private let fileSystem: any MSPWorkspaceFileSystem
    private let path: String
    private let currentDirectory: String
    private let creationMode: UInt16?
    private var closed = false

    init(
        fileSystem: any MSPWorkspaceFileSystem,
        path: String,
        currentDirectory: String,
        creationMode: UInt16?
    ) {
        self.fileSystem = fileSystem
        self.path = path
        self.currentDirectory = currentDirectory
        self.creationMode = creationMode
    }

    func write(_ data: Data) throws {
        guard !closed else {
            throw MSPCommandStreamError.writeError("Bad file descriptor")
        }
        guard !data.isEmpty else {
            return
        }
        try fileSystem.appendFile(
            path,
            data: data,
            from: currentDirectory,
            options: [],
            creationMode: creationMode
        )
    }

    func closeWrite() {
        closed = true
    }
}

private actor MSPWorkspaceFileInputStreamStorage {
    private let fileSystem: any MSPWorkspaceFileSystem
    private let path: String
    private let currentDirectory: String
    private let chunkSize: Int
    private var offset: UInt64 = 0
    private var closed = false
    private var attemptedSequentialOpen = false
    private var sequentialReader: (any MSPWorkspaceSequentialFileReader)?

    init(
        fileSystem: any MSPWorkspaceFileSystem,
        path: String,
        currentDirectory: String,
        chunkSize: Int
    ) {
        self.fileSystem = fileSystem
        self.path = path
        self.currentDirectory = currentDirectory
        self.chunkSize = chunkSize
    }

    func read(maxBytes: Int) throws -> Data? {
        guard !closed else {
            return nil
        }
        let requestedLength = max(1, min(maxBytes, chunkSize))
        if let sequentialReader = try openSequentialReaderIfAvailable() {
            let chunk = try sequentialReader.read(upToCount: requestedLength) ?? Data()
            guard !chunk.isEmpty else {
                try closeSequentialReader()
                return nil
            }
            return chunk
        }
        let chunk = try fileSystem.readFileRange(
            path,
            from: currentDirectory,
            offset: offset,
            length: requestedLength
        )
        guard !chunk.isEmpty else {
            return nil
        }
        offset += UInt64(chunk.count)
        return chunk
    }

    func closeRead() {
        closed = true
        try? closeSequentialReader()
    }

    private func openSequentialReaderIfAvailable() throws -> (any MSPWorkspaceSequentialFileReader)? {
        if let sequentialReader {
            return sequentialReader
        }
        guard !attemptedSequentialOpen else {
            return nil
        }
        attemptedSequentialOpen = true
        guard let sequentialFileSystem = fileSystem as? any MSPWorkspaceSequentialFileReading else {
            return nil
        }
        let reader = try sequentialFileSystem.openSequentialFileReader(path, from: currentDirectory)
        sequentialReader = reader
        return reader
    }

    private func closeSequentialReader() throws {
        if let reader = sequentialReader {
            sequentialReader = nil
            try reader.close()
        }
    }
}

private actor MSPDataInputStreamStorage {
    private let data: Data
    private var offset = 0
    private var closed = false

    init(data: Data) {
        self.data = data
    }

    func read(maxBytes: Int) -> Data? {
        guard !closed, offset < data.count else {
            return nil
        }
        let length = max(1, maxBytes)
        let end = min(offset + length, data.count)
        let chunk = data.subdata(in: offset..<end)
        offset = end
        return chunk
    }

    func closeRead() {
        closed = true
    }
}

public final class MSPCommandOutputBuffer: MSPCommandOutputStream {
    private let storage = MSPCommandOutputBufferStorage()

    public init() {}

    public func write(_ data: Data) async throws {
        await storage.append(data)
    }

    public func closeWrite() async {
        await storage.close()
    }

    public func data() async -> Data {
        await storage.data()
    }
}

private actor MSPCommandOutputBufferStorage {
    private var buffer = Data()

    func append(_ data: Data) {
        guard !data.isEmpty else {
            return
        }
        buffer.append(data)
    }

    func close() {}

    func data() -> Data {
        buffer
    }
}

public final class MSPClosureOutputStream: MSPCommandOutputStream {
    public typealias Handler = @Sendable (Data) async throws -> Void
    public typealias CloseHandler = @Sendable () async -> Void

    private let handler: Handler
    private let closeHandler: CloseHandler?

    public init(
        handler: @escaping Handler,
        closeHandler: CloseHandler? = nil
    ) {
        self.handler = handler
        self.closeHandler = closeHandler
    }

    public func write(_ data: Data) async throws {
        try await handler(data)
    }

    public func closeWrite() async {
        await closeHandler?()
    }
}

public final class MSPTeeOutputStream: MSPCommandOutputStream {
    private let streams: [any MSPCommandOutputStream]

    public init(_ streams: [any MSPCommandOutputStream]) {
        self.streams = streams
    }

    public func write(_ data: Data) async throws {
        for stream in streams {
            try await stream.write(data)
        }
    }

    public func closeWrite() async {
        for stream in streams {
            await stream.closeWrite()
        }
    }
}

public final class MSPBlackHoleOutputStream: MSPCommandOutputStream {
    public init() {}

    public func write(_ data: Data) async throws {}
}

public final class MSPClosedOutputStream: MSPCommandOutputStream {
    private let reason: String

    public init(reason: String = "standard output: Bad file descriptor") {
        self.reason = reason
    }

    public func write(_ data: Data) async throws {
        guard !data.isEmpty else {
            return
        }
        throw MSPCommandStreamError.writeError(reason)
    }
}

public final class MSPAsyncBytePipe: MSPCommandInputStream, MSPCommandOutputStream {
    private let storage: MSPAsyncBytePipeStorage

    public init(maxBufferedChunks: Int = 32) {
        self.storage = MSPAsyncBytePipeStorage(maxBufferedChunks: max(1, maxBufferedChunks))
    }

    public func read(maxBytes: Int) async throws -> Data? {
        await storage.read(maxBytes: maxBytes)
    }

    public func write(_ data: Data) async throws {
        try await storage.write(data)
    }

    public func closeRead() async {
        await storage.closeRead()
    }

    public func closeWrite() async {
        await storage.closeWrite()
    }
}

private actor MSPAsyncBytePipeStorage {
    private let maxBufferedChunks: Int
    private var chunks: [Data] = []
    private var writerClosed = false
    private var readerClosed = false
    private var waitingReaders: [CheckedContinuation<Data?, Never>] = []
    private var waitingWriters: [(Data, CheckedContinuation<Void, Error>)] = []

    init(maxBufferedChunks: Int) {
        self.maxBufferedChunks = maxBufferedChunks
    }

    func read(maxBytes: Int) async -> Data? {
        if readerClosed {
            return nil
        }
        if !chunks.isEmpty {
            let chunk = chunks.removeFirst()
            resumeWaitingWritersIfPossible()
            return chunk
        }
        if writerClosed {
            return nil
        }
        return await withCheckedContinuation { continuation in
            waitingReaders.append(continuation)
        }
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else {
            return
        }
        if readerClosed {
            throw MSPCommandStreamError.brokenPipe
        }
        if let reader = popWaitingReader() {
            reader.resume(returning: data)
            return
        }
        if chunks.count < maxBufferedChunks {
            chunks.append(data)
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            waitingWriters.append((data, continuation))
        }
    }

    func closeRead() {
        guard !readerClosed else {
            return
        }
        readerClosed = true
        chunks.removeAll(keepingCapacity: false)
        let readers = waitingReaders
        waitingReaders.removeAll()
        readers.forEach { $0.resume(returning: nil) }
        let writers = waitingWriters
        waitingWriters.removeAll()
        writers.forEach { $0.1.resume(throwing: MSPCommandStreamError.brokenPipe) }
    }

    func closeWrite() {
        guard !writerClosed else {
            return
        }
        writerClosed = true
        let readers = waitingReaders
        waitingReaders.removeAll()
        readers.forEach { $0.resume(returning: nil) }
        let writers = waitingWriters
        waitingWriters.removeAll()
        writers.forEach { $0.1.resume() }
    }

    private func resumeWaitingWritersIfPossible() {
        while !readerClosed, chunks.count < maxBufferedChunks, !waitingWriters.isEmpty {
            let (data, continuation) = waitingWriters.removeFirst()
            if let reader = popWaitingReader() {
                reader.resume(returning: data)
            } else {
                chunks.append(data)
            }
            continuation.resume()
        }
    }

    private func popWaitingReader() -> CheckedContinuation<Data?, Never>? {
        guard !waitingReaders.isEmpty else {
            return nil
        }
        return waitingReaders.removeFirst()
    }
}
