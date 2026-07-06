import Foundation
import XCTest
import MSPCore
import MSPPOSIXCore

final class MSPXargsCommandRegressionTests: XCTestCase {
    func testDelimitedModesPreserveEmptyArgumentsAndIgnoreEOFMarker() async throws {
        let capture = XargsCommandLineCapture()
        let runner: MSPCommandLineRunner = { commandLine, _ in
            await capture.append(commandLine)
            return .success(stdout: commandLine + "\n")
        }

        let nullResult = try await MSPXargsCommand().run(
            invocation: MSPCommandInvocation(name: "xargs", arguments: ["-0", "-E", "STOP", "-n", "1", "echo"]),
            context: MSPCommandContext(
                standardInput: Data("a\0\0STOP\0b\0".utf8),
                commandLineRunner: runner
            )
        )
        let delimiterResult = try await MSPXargsCommand().run(
            invocation: MSPCommandInvocation(name: "xargs", arguments: ["-d", ",", "-E", "STOP", "-n", "1", "printf"]),
            context: MSPCommandContext(
                standardInput: Data("left,,STOP,right,".utf8),
                commandLineRunner: runner
            )
        )

        let capturedLines = await capture.lines()
        XCTAssertEqual(capturedLines, [
            "echo a",
            "echo ''",
            "echo STOP",
            "echo b",
            "printf left",
            "printf ''",
            "printf STOP",
            "printf right"
        ])
        XCTAssertEqual(nullResult.exitCode, 0)
        XCTAssertEqual(delimiterResult.exitCode, 0)
    }

    func testStreamingDelimitedModesPreserveEmptyArgumentsAndIgnoreEOFMarker() async throws {
        let capture = XargsCommandLineCapture()
        let runner: MSPCommandLineRunner = { commandLine, _ in
            await capture.append(commandLine)
            return .success(stdout: commandLine + "\n")
        }
        let nullOutput = XargsCollectingOutputStream()
        let delimiterOutput = XargsCollectingOutputStream()

        let nullResult = try await MSPXargsCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "xargs", arguments: ["-0", "-E", "STOP", "-n", "1", "echo"]),
            context: MSPCommandContext(
                standardInputStream: XargsChunkedInputStream(["a\0\0STOP\0", "b\0"]),
                standardOutputStream: nullOutput,
                commandLineRunner: runner
            )
        )
        let delimiterResult = try await MSPXargsCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "xargs", arguments: ["-d", ",", "-E", "STOP", "-n", "1", "printf"]),
            context: MSPCommandContext(
                standardInputStream: XargsChunkedInputStream(["left,,", "STOP,right,"]),
                standardOutputStream: delimiterOutput,
                commandLineRunner: runner
            )
        )

        let capturedLines = await capture.lines()
        XCTAssertEqual(capturedLines, [
            "echo a",
            "echo ''",
            "echo STOP",
            "echo b",
            "printf left",
            "printf ''",
            "printf STOP",
            "printf right"
        ])
        let nullOutputText = await nullOutput.string()
        let delimiterOutputText = await delimiterOutput.string()
        XCTAssertEqual(nullOutputText, "echo a\necho ''\necho STOP\necho b\n")
        XCTAssertEqual(delimiterOutputText, "printf left\nprintf ''\nprintf STOP\nprintf right\n")
        XCTAssertEqual(nullResult.exitCode, 0)
        XCTAssertEqual(delimiterResult.exitCode, 0)
    }

    func testDefaultParsingRejectsQuotedArgumentAcrossNewline() async throws {
        let capture = XargsCommandLineCapture()
        let runner: MSPCommandLineRunner = { commandLine, _ in
            await capture.append(commandLine)
            return .success(stdout: commandLine + "\n")
        }

        do {
            _ = try await MSPXargsCommand().run(
                invocation: MSPCommandInvocation(name: "xargs", arguments: ["echo"]),
                context: MSPCommandContext(
                    standardInput: Data("\"a\nb\"\n".utf8),
                    commandLineRunner: runner
                )
            )
            XCTFail("Expected unmatched quote failure")
        } catch let failure as MSPCommandFailure {
            XCTAssertEqual(failure.result.exitCode, 1)
            XCTAssertEqual(
                failure.result.stderr,
                "xargs: unmatched double quote; by default quotes are special to xargs unless you use the -0 option\n"
            )
        }
        let capturedLines = await capture.lines()
        XCTAssertEqual(capturedLines, [])
    }

    func testStreamingEOFMarkerClosesUpstreamBeforeReadingRemainingChunks() async throws {
        let capture = XargsCommandLineCapture()
        let runner: MSPCommandLineRunner = { commandLine, _ in
            await capture.append(commandLine)
            return .success(stdout: commandLine + "\n")
        }
        let defaultInput = XargsChunkedInputStream(["a STOP ", "b "])
        let logicalLineInput = XargsChunkedInputStream(["one\nSTOP\n", "two\n"])
        let defaultOutput = XargsCollectingOutputStream()
        let logicalLineOutput = XargsCollectingOutputStream()

        let defaultResult = try await MSPXargsCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "xargs", arguments: ["-E", "STOP", "-n", "1", "echo"]),
            context: MSPCommandContext(
                standardInputStream: defaultInput,
                standardOutputStream: defaultOutput,
                commandLineRunner: runner
            )
        )
        let logicalLineResult = try await MSPXargsCommand().runStreaming(
            invocation: MSPCommandInvocation(name: "xargs", arguments: ["-E", "STOP", "-L", "1", "printf"]),
            context: MSPCommandContext(
                standardInputStream: logicalLineInput,
                standardOutputStream: logicalLineOutput,
                commandLineRunner: runner
            )
        )

        let capturedLines = await capture.lines()
        let defaultReadCount = await defaultInput.readCount()
        let logicalLineReadCount = await logicalLineInput.readCount()
        let defaultIsReadClosed = await defaultInput.isReadClosed()
        let logicalLineIsReadClosed = await logicalLineInput.isReadClosed()
        let defaultOutputText = await defaultOutput.string()
        let logicalLineOutputText = await logicalLineOutput.string()
        XCTAssertEqual(capturedLines, ["echo a", "printf one"])
        XCTAssertEqual(defaultReadCount, 1)
        XCTAssertEqual(logicalLineReadCount, 1)
        XCTAssertTrue(defaultIsReadClosed)
        XCTAssertTrue(logicalLineIsReadClosed)
        XCTAssertEqual(defaultOutputText, "echo a\n")
        XCTAssertEqual(logicalLineOutputText, "printf one\n")
        XCTAssertEqual(defaultResult.exitCode, 0)
        XCTAssertEqual(logicalLineResult.exitCode, 0)
    }
}
