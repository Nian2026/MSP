import Foundation
import XCTest
import MSPCore
import MSPPOSIXCore

final class MSPTextStreamCommandTests: XCTestCase {
    func testCatCopiesInputChunksToOutputStream() async throws {
        let input = ChunkedInputStream(chunks: [
            Data([0xff, 0x41]),
            Data("bc\n".utf8)
        ])
        let output = CollectingOutputStream()

        let result = try await MSPCatCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "cat"),
            context: streamingContext(input: input, output: output)
        )

        XCTAssertEqual(result.exitCode, 0)
        var expected = Data([0xff, 0x41])
        expected.append(contentsOf: "bc\n".utf8)
        let outputData = await output.data()
        let outputWriteCount = await output.writeCount()
        let inputReadCount = await input.readCount()
        let inputCloseReadCount = await input.closeReadCount()
        XCTAssertEqual(outputData, expected)
        XCTAssertEqual(outputWriteCount, 2)
        XCTAssertEqual(inputReadCount, 2)
        XCTAssertEqual(inputCloseReadCount, 0)
    }

    func testHeadClosesInputStreamAfterRequestedLines() async throws {
        let input = ChunkedInputStream(chunks: Array(repeating: Data("ok\n".utf8), count: 1_000))
        let output = CollectingOutputStream()

        let result = try await MSPHeadCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "head", arguments: ["-n", "3"]),
            context: streamingContext(input: input, output: output)
        )

        XCTAssertEqual(result.exitCode, 0)
        let outputText = String(decoding: await output.data(), as: UTF8.self)
        let inputCloseReadCount = await input.closeReadCount()
        let inputReadCount = await input.readCount()
        XCTAssertEqual(outputText, "ok\nok\nok\n")
        XCTAssertEqual(inputCloseReadCount, 1)
        XCTAssertLessThan(inputReadCount, 1_000)
    }

    func testHeadAllButLastLinesBuffersTrailingRecordWindow() async throws {
        let input = ChunkedInputStream(chunks: [
            Data("1\n2\n".utf8),
            Data("3\n4\n5\n".utf8)
        ])
        let output = CollectingOutputStream()

        let result = try await MSPHeadCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "head", arguments: ["-n", "-2"]),
            context: streamingContext(input: input, output: output)
        )

        XCTAssertEqual(result.exitCode, 0)
        let outputText = String(decoding: await output.data(), as: UTF8.self)
        XCTAssertEqual(outputText, "1\n2\n3\n")
    }

    func testTailKeepsOnlyRequestedRecordWindowFromInputStream() async throws {
        let input = ChunkedInputStream(chunks: (0..<1_000).map { Data("row-\($0)\n".utf8) })
        let output = CollectingOutputStream()

        let result = try await MSPTailCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "tail", arguments: ["-n", "3"]),
            context: streamingContext(input: input, output: output)
        )

        XCTAssertEqual(result.exitCode, 0)
        let outputText = String(decoding: await output.data(), as: UTF8.self)
        let inputReadCount = await input.readCount()
        XCTAssertEqual(outputText, "row-997\nrow-998\nrow-999\n")
        XCTAssertEqual(inputReadCount, 1_000)
    }

    func testTailFromStartStreamsAfterSkippedRecords() async throws {
        let input = ChunkedInputStream(chunks: [
            Data("one\n".utf8),
            Data("two\nthree\n".utf8),
            Data("four\n".utf8)
        ])
        let output = CollectingOutputStream()

        let result = try await MSPTailCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "tail", arguments: ["-n", "+3"]),
            context: streamingContext(input: input, output: output)
        )

        XCTAssertEqual(result.exitCode, 0)
        let outputText = String(decoding: await output.data(), as: UTF8.self)
        XCTAssertEqual(outputText, "three\nfour\n")
    }

    func testTailKeepsOnlyRequestedByteWindowFromInputStream() async throws {
        let input = ChunkedInputStream(chunks: [
            Data("abc".utf8),
            Data("def".utf8),
            Data("ghi".utf8)
        ])
        let output = CollectingOutputStream()

        let result = try await MSPTailCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "tail", arguments: ["-c", "4"]),
            context: streamingContext(input: input, output: output)
        )

        XCTAssertEqual(result.exitCode, 0)
        let outputText = String(decoding: await output.data(), as: UTF8.self)
        XCTAssertEqual(outputText, "fghi")
    }

    func testWcStreamingKeepsUTF8ScalarsAcrossChunkBoundaries() async throws {
        let input = ChunkedInputStream(chunks: [
            Data([0xE4, 0xB8]),
            Data([0xAD, 0x0A])
        ])
        let output = CollectingOutputStream()

        let result = try await MSPWcCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "wc", arguments: ["-m", "-c", "-L"]),
            context: streamingContext(input: input, output: output)
        )

        XCTAssertEqual(result.exitCode, 0)
        let outputText = String(decoding: await output.data(), as: UTF8.self)
        XCTAssertEqual(outputText, "      2       4       2\n")
    }

    func testWcStreamingTreatsBrokenOutputPipeAsSuccess() async throws {
        let input = ChunkedInputStream(chunks: [
            Data("abc".utf8),
            Data("def\n".utf8)
        ])
        let output = CollectingOutputStream(failAfterWrites: 0)

        let result = try await MSPWcCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "wc", arguments: ["-c"]),
            context: streamingContext(input: input, output: output)
        )

        XCTAssertEqual(result.exitCode, 0)
        let outputData = await output.data()
        let outputWriteCount = await output.writeCount()
        let inputReadCount = await input.readCount()
        let inputCloseReadCount = await input.closeReadCount()
        XCTAssertEqual(outputData, Data())
        XCTAssertEqual(outputWriteCount, 0)
        XCTAssertEqual(inputReadCount, 2)
        XCTAssertEqual(inputCloseReadCount, 0)
    }

    func testExpandStreamsTabStateAcrossInputChunks() async throws {
        let input = ChunkedInputStream(chunks: [
            Data("\ta\t".utf8),
            Data("b\n".utf8)
        ])
        let output = CollectingOutputStream()

        let result = try await MSPExpandCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "expand", arguments: ["-i", "-t", "4"]),
            context: streamingContext(input: input, output: output)
        )

        XCTAssertEqual(result.exitCode, 0)
        let outputText = String(decoding: await output.data(), as: UTF8.self)
        let outputWriteCount = await output.writeCount()
        XCTAssertEqual(outputText, "    a\tb\n")
        XCTAssertEqual(outputWriteCount, 2)
    }

    func testFoldStreamsLineStateAcrossInputChunks() async throws {
        let input = ChunkedInputStream(chunks: [
            Data("aa ".utf8),
            Data("bb c".utf8),
            Data("c\nabcdef".utf8)
        ])
        let output = CollectingOutputStream()

        let result = try await MSPFoldCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "fold", arguments: ["-s", "-w", "5"]),
            context: streamingContext(input: input, output: output)
        )

        XCTAssertEqual(result.exitCode, 0)
        let outputText = String(decoding: await output.data(), as: UTF8.self)
        let inputReadCount = await input.readCount()
        XCTAssertEqual(outputText, "aa \nbb cc\nabcde\nf")
        XCTAssertEqual(inputReadCount, 3)
    }

    func testUnexpandStreamsCompletedLinesAcrossInputChunks() async throws {
        let input = ChunkedInputStream(chunks: [
            Data("    x\n".utf8),
            Data("a   b\n".utf8)
        ])
        let output = CollectingOutputStream()

        let result = try await MSPUnexpandCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "unexpand", arguments: ["-a", "-t", "4"]),
            context: streamingContext(input: input, output: output)
        )

        XCTAssertEqual(result.exitCode, 0)
        let outputText = String(decoding: await output.data(), as: UTF8.self)
        let outputWriteCount = await output.writeCount()
        XCTAssertEqual(outputText, "\tx\na\tb\n")
        XCTAssertEqual(outputWriteCount, 2)
    }

    func testSedQuitClosesInputStreamEarly() async throws {
        let chunks = (0..<1_000).map { Data("row-\($0)\n".utf8) }
        let input = ChunkedInputStream(chunks: chunks)
        let output = CollectingOutputStream()

        let result = try await MSPSedCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "sed", arguments: ["1q"]),
            context: streamingContext(input: input, output: output)
        )

        XCTAssertEqual(result.exitCode, 0)
        let outputText = String(decoding: await output.data(), as: UTF8.self)
        let inputCloseReadCount = await input.closeReadCount()
        let inputReadCount = await input.readCount()
        XCTAssertEqual(outputText, "row-0\n")
        XCTAssertEqual(inputCloseReadCount, 1)
        XCTAssertLessThan(inputReadCount, chunks.count)
    }

    func testYesStopsWhenOutputStreamBreaksPipe() async throws {
        let output = CollectingOutputStream(failAfterWrites: 3)

        let result = try await MSPYesCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "yes", arguments: ["x"]),
            context: MSPCommandContext(standardOutputStream: output)
        )

        XCTAssertEqual(result.exitCode, 0)
        let outputText = String(decoding: await output.data(), as: UTF8.self)
        let outputWriteCount = await output.writeCount()
        XCTAssertEqual(outputText, "x\nx\nx\n")
        XCTAssertEqual(outputWriteCount, 3)
    }

    func testSeqStopsWhenOutputStreamBreaksPipe() async throws {
        let output = LineLimitingOutputStream(maxLines: 3)

        let result = try await MSPSeqCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "seq", arguments: ["1", "1000000"]),
            context: MSPCommandContext(standardOutputStream: output)
        )

        XCTAssertEqual(result.exitCode, 0)
        let outputText = await output.string()
        let didBreakPipe = await output.didBreakPipe()
        XCTAssertEqual(outputText, "1\n2\n3\n")
        XCTAssertTrue(didBreakPipe)
    }

    private func streamingContext(
        input: any MSPCommandInputStream,
        output: any MSPCommandOutputStream
    ) -> MSPCommandContext {
        MSPCommandContext(
            standardInputStream: input,
            standardOutputStream: output
        )
    }
}

private final class ChunkedInputStream: MSPCommandInputStream, @unchecked Sendable {
    private let storage: ChunkedInputStreamStorage

    init(chunks: [Data]) {
        self.storage = ChunkedInputStreamStorage(chunks: chunks)
    }

    func read(maxBytes: Int) async throws -> Data? {
        await storage.read(maxBytes: maxBytes)
    }

    func closeRead() async {
        await storage.closeRead()
    }

    func readCount() async -> Int {
        await storage.readCount()
    }

    func closeReadCount() async -> Int {
        await storage.closeReadCount()
    }
}

private actor ChunkedInputStreamStorage {
    private let chunks: [Data]
    private var offset = 0
    private var isClosed = false
    private var reads = 0
    private var closeReads = 0

    init(chunks: [Data]) {
        self.chunks = chunks
    }

    func read(maxBytes: Int) -> Data? {
        guard !isClosed, offset < chunks.count else {
            return nil
        }
        reads += 1
        let chunk = chunks[offset]
        offset += 1
        return chunk
    }

    func closeRead() {
        isClosed = true
        closeReads += 1
    }

    func readCount() -> Int {
        reads
    }

    func closeReadCount() -> Int {
        closeReads
    }
}

private final class CollectingOutputStream: MSPCommandOutputStream, @unchecked Sendable {
    private let storage: CollectingOutputStreamStorage

    init(failAfterWrites: Int? = nil) {
        self.storage = CollectingOutputStreamStorage(failAfterWrites: failAfterWrites)
    }

    func write(_ data: Data) async throws {
        try await storage.write(data)
    }

    func closeWrite() async {
        await storage.closeWrite()
    }

    func data() async -> Data {
        await storage.data()
    }

    func writeCount() async -> Int {
        await storage.writeCount()
    }
}

private actor CollectingOutputStreamStorage {
    private let failAfterWrites: Int?
    private var buffer = Data()
    private var writes = 0
    private var isClosed = false

    init(failAfterWrites: Int?) {
        self.failAfterWrites = failAfterWrites
    }

    func write(_ data: Data) throws {
        guard !isClosed else {
            throw MSPCommandStreamError.brokenPipe
        }
        if let failAfterWrites, writes >= failAfterWrites {
            throw MSPCommandStreamError.brokenPipe
        }
        guard !data.isEmpty else {
            return
        }
        writes += 1
        buffer.append(data)
    }

    func closeWrite() {
        isClosed = true
    }

    func data() -> Data {
        buffer
    }

    func writeCount() -> Int {
        writes
    }
}

private final class LineLimitingOutputStream: MSPCommandOutputStream, @unchecked Sendable {
    private let storage: LineLimitingOutputStreamStorage

    init(maxLines: Int) {
        self.storage = LineLimitingOutputStreamStorage(maxLines: maxLines)
    }

    func write(_ data: Data) async throws {
        try await storage.write(data)
    }

    func closeWrite() async {}

    func string() async -> String {
        await storage.string()
    }

    func didBreakPipe() async -> Bool {
        await storage.didBreakPipe()
    }
}

private actor LineLimitingOutputStreamStorage {
    private let maxLines: Int
    private var lines = 0
    private var text = ""
    private var broken = false

    init(maxLines: Int) {
        self.maxLines = max(0, maxLines)
    }

    func write(_ data: Data) throws {
        guard !broken else {
            throw MSPCommandStreamError.brokenPipe
        }
        let chunk = String(decoding: data, as: UTF8.self)
        for character in chunk {
            text.append(character)
            if character == "\n" {
                lines += 1
                if lines >= maxLines {
                    broken = true
                    throw MSPCommandStreamError.brokenPipe
                }
            }
        }
    }

    func string() -> String {
        text
    }

    func didBreakPipe() -> Bool {
        broken
    }
}
