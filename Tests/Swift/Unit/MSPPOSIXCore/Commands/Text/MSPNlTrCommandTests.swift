import Foundation
import XCTest
import MSPCore
import MSPPOSIXCore

final class MSPNlTrCommandTests: XCTestCase {
    func testNlAndTrSupportGNUStandardOptions() async throws {
        let nlHelp = await runNl(["--help"], stdin: "")
        let nlVersion = await runNl(["--version"], stdin: "")
        let trHelp = await runTr(["--help"], stdin: "")
        let trVersion = await runTr(["--version"], stdin: "")

        XCTAssertTrue(nlHelp.stdout.hasPrefix("Usage: nl [OPTION]... [FILE]...\n"))
        XCTAssertEqual(nlVersion.stdout, "nl (GNU coreutils) 9.1\n")
        XCTAssertTrue(trHelp.stdout.hasPrefix("Usage: tr [OPTION]... STRING1 [STRING2]\n"))
        XCTAssertEqual(trVersion.stdout, "tr (GNU coreutils) 9.1\n")
    }

    func testNlRecognizesDefaultSectionDelimitersAndSectionStyles() async throws {
        let result = await runNl(
            ["-h", "a", "-b", "a", "-f", "a", "-w", "2", "-s", ":"],
            stdin: "intro\n\\:\\:\\:\nhead\n\\:\\:\nbody\n\\:\nfoot\n"
        )

        XCTAssertEqual(result.stdout, " 1:intro\n\n 1:head\n\n 1:body\n\n 1:foot\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testNlNoRenumberPreservesLineNumberAcrossSections() async throws {
        let result = await runNl(
            ["-b", "a", "-p", "-w", "1", "-s", ":"],
            stdin: "one\n\\:\\:\ntwo\n"
        )

        XCTAssertEqual(result.stdout, "1:one\n\n2:two\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testNlCustomSectionDelimiterAndPatternStyle() async throws {
        let delimiter = await runNl(
            ["-b", "a", "-d", "::", "-w", "1", "-s", ":"],
            stdin: "a\n::::\nb\n"
        )
        let pattern = await runNl(
            ["-b", "p^A", "-w", "1", "-s", ":"],
            stdin: "A\nB\nAA\n"
        )

        XCTAssertEqual(delimiter.stdout, "1:a\n\n1:b\n")
        XCTAssertEqual(pattern.stdout, "1:A\n  B\n2:AA\n")
        XCTAssertEqual(delimiter.exitCode, 0)
        XCTAssertEqual(pattern.exitCode, 0)
    }

    func testNlJoinBlankLinesNumbersEveryNthBlankLine() async throws {
        let result = await runNl(
            ["-b", "a", "-l", "2", "-w", "1", "-s", ":"],
            stdin: "\n\n\nx\n"
        )

        XCTAssertEqual(result.stdout, "  \n1:\n  \n2:x\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testNlDoesNotAddNewlineToFinalUnterminatedRecord() async throws {
        let eager = await runNl(["-b", "a"], stdin: Data("tail".utf8))
        let input = MSPDataInputStream(Data("tail".utf8))
        let output = ByteCollectingOutputStream()

        let streaming = try await MSPNlCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "nl", arguments: ["-b", "a"]),
            context: MSPCommandContext(
                standardInputStream: input,
                standardOutputStream: output
            )
        )
        let streamingOutput = await output.data()

        XCTAssertEqual(eager.stdoutData, Data("     1\ttail".utf8))
        XCTAssertEqual(eager.stderr, "")
        XCTAssertEqual(eager.exitCode, 0)
        XCTAssertEqual(streamingOutput, Data("     1\ttail".utf8))
        XCTAssertEqual(streaming.stderr, "")
        XCTAssertEqual(streaming.exitCode, 0)
    }

    func testNlReportsInvalidSectionStyleDiagnostics() async throws {
        let result = await runNl(["-f", "bad"], stdin: "x\n")

        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "nl: invalid footer numbering style: \u{2018}bad\u{2019}\n")
        XCTAssertEqual(result.exitCode, 1)
    }

    func testTrSupportsOctalEscapesAndExplicitRepeatConstructs() async throws {
        let octal = await runTr(["\\141\\142", "XY"], stdin: "ababa\n")
        let repeated = await runTr(["abc", "[X*3]"], stdin: "abc cab\n")
        let deleteNewlines = await runTr(["-d", "\\012"], stdin: "a\nb\n")

        XCTAssertEqual(octal.stdout, "XYXYX\n")
        XCTAssertEqual(repeated.stdout, "XXX XXX\n")
        XCTAssertEqual(deleteNewlines.stdout, "ab")
        XCTAssertEqual(octal.exitCode, 0)
        XCTAssertEqual(repeated.exitCode, 0)
        XCTAssertEqual(deleteNewlines.exitCode, 0)
    }

    func testTrByteTableHandlesNULAndHighBytes() async throws {
        let deleteNUL = await runTr(["-d", "\\000"], stdin: Data([0x41, 0x00, 0x42, 0x00]))
        let translateHighByte = await runTr(["\\377", "X"], stdin: Data([0xff, 0x41, 0xff]))
        let complementNUL = await runTr(["-c", "\\000", "X"], stdin: Data([0x00, 0xff, 0x41]))
        let squeezeNUL = await runTr(["-s", "\\000"], stdin: Data([0x00, 0x00, 0x41, 0x00, 0x00]))

        XCTAssertEqual(deleteNUL.stdoutData, Data([0x41, 0x42]))
        XCTAssertEqual(translateHighByte.stdoutData, Data([0x58, 0x41, 0x58]))
        XCTAssertEqual(complementNUL.stdoutData, Data([0x00, 0x58, 0x58]))
        XCTAssertEqual(squeezeNUL.stdoutData, Data([0x00, 0x41, 0x00]))
        XCTAssertEqual(deleteNUL.exitCode, 0)
        XCTAssertEqual(translateHighByte.exitCode, 0)
        XCTAssertEqual(complementNUL.exitCode, 0)
        XCTAssertEqual(squeezeNUL.exitCode, 0)
    }

    func testTrStreamingScalarFallbackPreservesSplitUTF8Scalars() async throws {
        let input = FixedChunkInputStream([
            Data([0x63, 0x61, 0x66, 0xC3]),
            Data([0xA9, 0x0A, 0xC3]),
            Data([0xA9])
        ])
        let output = ByteCollectingOutputStream()

        let result = try await MSPTrCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "tr", arguments: ["é", "ø"]),
            context: MSPCommandContext(
                standardInputStream: input,
                standardOutputStream: output
            )
        )

        let outputData = await output.data()
        XCTAssertEqual(outputData, Data("cafø\nø".utf8))
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testTrScalarFallbackHandlesSqueezeAndDeleteSqueeze() async throws {
        let squeeze = await runTr(["-s", "é"], stdin: "cafééé\néé")
        let deleteThenSqueeze = await runTr(["-d", "-s", "é", "ø"], stdin: "éøøéø")

        XCTAssertEqual(squeeze.stdout, "café\né")
        XCTAssertEqual(squeeze.exitCode, 0)
        XCTAssertEqual(deleteThenSqueeze.stdout, "ø")
        XCTAssertEqual(deleteThenSqueeze.exitCode, 0)
    }

    func testTrPOSIXClassesComplementAndDeleteSqueezeUseByteTables() async throws {
        let upper = await runTr(["[:lower:]", "[:upper:]"], stdin: "abc XYZ\n")
        let complementSqueeze = await runTr(["-cs", "[:alnum:]", "\\n"], stdin: Data([0xff, 0x41, 0xff, 0xff, 0x42]))
        let deleteThenSqueeze = await runTr(["-d", "-s", "[:digit:]", "x"], stdin: "112xxxy\n")

        XCTAssertEqual(upper.stdout, "ABC XYZ\n")
        XCTAssertEqual(complementSqueeze.stdoutData, Data([0x0A, 0x41, 0x0A, 0x42]))
        XCTAssertEqual(deleteThenSqueeze.stdout, "xy\n")
        XCTAssertEqual(upper.exitCode, 0)
        XCTAssertEqual(complementSqueeze.exitCode, 0)
        XCTAssertEqual(deleteThenSqueeze.exitCode, 0)
    }

    func testTrByteTableStreamsLargeNULInput() async throws {
        var inputData = Data()
        for _ in 0..<20_000 {
            inputData.append(0x00)
            inputData.append(0xff)
            inputData.append(0x41)
        }
        let input = MSPDataInputStream(inputData)
        let output = ByteCollectingOutputStream()

        let result = try await MSPTrCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "tr", arguments: ["-d", "\\000"]),
            context: MSPCommandContext(
                standardInputStream: input,
                standardOutputStream: output
            )
        )

        var expected = Data()
        for _ in 0..<20_000 {
            expected.append(0xff)
            expected.append(0x41)
        }
        let actual = await output.data()
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(result.exitCode, 0)
    }

    func testTrReportsGNUOperandCountDiagnostics() async throws {
        let deleteExtra = await runTr(["-d", "a", "b"], stdin: "a")
        let deleteSqueezeMissing = await runTr(["-d", "-s", "a"], stdin: "aa")

        XCTAssertEqual(deleteExtra.stdout, "")
        XCTAssertEqual(
            deleteExtra.stderr,
            "tr: extra operand \u{2018}b\u{2019}\nOnly one string may be given when deleting without squeezing repeats.\nTry 'tr --help' for more information.\n"
        )
        XCTAssertEqual(deleteExtra.exitCode, 1)
        XCTAssertEqual(deleteSqueezeMissing.stdout, "")
        XCTAssertEqual(
            deleteSqueezeMissing.stderr,
            "tr: missing operand after \u{2018}a\u{2019}\nTwo strings must be given when both deleting and squeezing repeats.\nTry 'tr --help' for more information.\n"
        )
        XCTAssertEqual(deleteSqueezeMissing.exitCode, 1)
    }

    private func runNl(_ arguments: [String], stdin: String) async -> MSPCommandResult {
        await runNl(arguments, stdin: Data(stdin.utf8))
    }

    private func runNl(_ arguments: [String], stdin: Data) async -> MSPCommandResult {
        do {
            return try await MSPNlCommand().run(
                invocation: MSPCommandInvocation(name: "nl", arguments: arguments),
                context: MSPCommandContext(standardInput: stdin)
            )
        } catch let error as MSPCommandFailure {
            return error.result
        } catch {
            return .failure(stderr: "nl: \(error)\n")
        }
    }

    private func runTr(_ arguments: [String], stdin: String) async -> MSPCommandResult {
        await runTr(arguments, stdin: Data(stdin.utf8))
    }

    private func runTr(_ arguments: [String], stdin: Data) async -> MSPCommandResult {
        do {
            return try await MSPTrCommand().run(
                invocation: MSPCommandInvocation(name: "tr", arguments: arguments),
                context: MSPCommandContext(standardInput: stdin)
            )
        } catch let error as MSPCommandFailure {
            return error.result
        } catch {
            return .failure(stderr: "tr: \(error)\n")
        }
    }
}

private final class ByteCollectingOutputStream: MSPCommandOutputStream, @unchecked Sendable {
    private let storage = ByteCollectingOutputStreamStorage()

    func write(_ data: Data) async throws {
        await storage.write(data)
    }

    func closeWrite() async {}

    func data() async -> Data {
        await storage.data()
    }
}

private actor ByteCollectingOutputStreamStorage {
    private var chunks = Data()

    func write(_ data: Data) {
        chunks.append(data)
    }

    func data() -> Data {
        chunks
    }
}

private final class FixedChunkInputStream: MSPCommandInputStream, @unchecked Sendable {
    private let storage: FixedChunkInputStreamStorage

    init(_ chunks: [Data]) {
        self.storage = FixedChunkInputStreamStorage(chunks: chunks)
    }

    func read(maxBytes: Int) async throws -> Data? {
        await storage.read()
    }
}

private actor FixedChunkInputStreamStorage {
    private var chunks: [Data]

    init(chunks: [Data]) {
        self.chunks = chunks
    }

    func read() -> Data? {
        guard !chunks.isEmpty else {
            return nil
        }
        return chunks.removeFirst()
    }
}
