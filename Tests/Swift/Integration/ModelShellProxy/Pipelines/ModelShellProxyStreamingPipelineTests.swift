import Foundation
import XCTest
import MSPAgentBridge
import MSPApple
import ModelShellProxy

final class ModelShellProxyStreamingPipelineTests: ModelShellProxyIntegrationTestCase {
    func testStreamingPipelineLetsHeadCloseInfiniteProducer() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let result = await shell.run("yes ok | head -n 3")
        let sedResult = await shell.run("yes ok | sed 's/o/O/' | head -n 3")
        let numericAlias = await shell.run("yes ok | head -3")
        let prefixSed = await shell.run("yes ok | sed 's#^#/#' | head -3")

        XCTAssertEqual(result.stdout, "ok\nok\nok\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(sedResult.stdout, "Ok\nOk\nOk\n")
        XCTAssertEqual(sedResult.stderr, "")
        XCTAssertEqual(sedResult.exitCode, 0)
        XCTAssertEqual(numericAlias.stdout, "ok\nok\nok\n")
        XCTAssertEqual(numericAlias.stderr, "")
        XCTAssertEqual(numericAlias.exitCode, 0)
        XCTAssertEqual(prefixSed.stdout, "/ok\n/ok\n/ok\n")
        XCTAssertEqual(prefixSed.stderr, "")
        XCTAssertEqual(prefixSed.exitCode, 0)
    }

    func testStreamingPipelineCompletesLargeHeadFromInfiniteProducer() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let result = await shell.run("yes ok | head -n 20000")
        let lineCount = result.stdout.split(separator: "\n", omittingEmptySubsequences: true).count

        XCTAssertEqual(lineCount, 20_000)
        XCTAssertTrue(result.stdout.hasPrefix("ok\nok\n"))
        XCTAssertTrue(result.stdout.hasSuffix("ok\n"))
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testStreamingPipelineLetsHeadCloseGeneratedSequence() async throws {
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let result = await shell.run("seq 1 1000000 | head -n 3")

        XCTAssertEqual(result.stdout, "1\n2\n3\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testSingleStreamingCommandEmitsOutputBeforeCompletionWhenObserved() async throws {
        let gate = GatedStreamingCommandGate()
        let output = StreamingOutputCapture()
        let registry = try MSPCommandRegistry(commands: [
            GatedStreamingCommand(gate: gate)
        ])
        let shell = ModelShellProxy(registry: registry)

        let task = Task {
            await shell.run("gated-stream", outputStream: output)
        }

        await gate.waitForFirstOutput()

        let firstOutput = await output.text()
        let wasReleasedBeforeCompletion = await gate.isReleased()
        XCTAssertEqual(firstOutput, "first\n")
        XCTAssertFalse(wasReleasedBeforeCompletion)

        await gate.release()
        let result = await task.value

        XCTAssertEqual(result.stdout, "first\nsecond\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        let finalOutput = await output.text()
        XCTAssertEqual(finalOutput, "first\nsecond\n")
        let wasReleasedAfterCompletion = await gate.isReleased()
        XCTAssertTrue(wasReleasedAfterCompletion)
    }

    func testShellLauncherForwardsChildStreamingOutputBeforeCompletionWhenObserved() async throws {
        let gate = GatedStreamingCommandGate()
        let output = StreamingOutputCapture()
        let registry = try MSPCommandRegistry(commands: [
            GatedStreamingCommand(gate: gate)
        ])
        let shell = ModelShellProxy(registry: registry)

        let task = Task {
            await shell.run("bash -lc 'gated-stream'", outputStream: output)
        }

        let didStreamFirstOutput = await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            await output.text() == "first\n"
        }

        let firstOutput = await output.text()
        let wasReleasedBeforeCompletion = await gate.isReleased()
        XCTAssertTrue(didStreamFirstOutput)
        XCTAssertEqual(firstOutput, "first\n")
        XCTAssertFalse(wasReleasedBeforeCompletion)

        await gate.release()
        let result = await task.value

        XCTAssertEqual(result.stdout, "first\nsecond\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        let wasReleasedAfterCompletion = await gate.isReleased()
        XCTAssertTrue(wasReleasedAfterCompletion)
    }

    func testForLoopForwardsBodyStreamingOutputBeforeCompletionWhenObserved() async throws {
        let gate = GatedStreamingCommandGate()
        let output = StreamingOutputCapture()
        let registry = try MSPCommandRegistry(commands: [
            GatedStreamingCommand(gate: gate)
        ])
        let shell = ModelShellProxy(registry: registry)

        let task = Task {
            await shell.run("for item in only; do gated-stream; done", outputStream: output)
        }

        let didStreamFirstOutput = await waitUntil(timeoutNanoseconds: 1_000_000_000) {
            await output.text() == "first\n"
        }

        let firstOutput = await output.text()
        let wasReleasedBeforeCompletion = await gate.isReleased()
        XCTAssertTrue(didStreamFirstOutput)
        XCTAssertEqual(firstOutput, "first\n")
        XCTAssertFalse(wasReleasedBeforeCompletion)

        await gate.release()
        let result = await task.value

        XCTAssertEqual(result.stdout, "first\nsecond\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        let finalOutput = await output.text()
        XCTAssertEqual(finalOutput, "first\nsecond\n")
        let wasReleasedAfterCompletion = await gate.isReleased()
        XCTAssertTrue(wasReleasedAfterCompletion)
    }

    func testForLoopStreamsRealPOSIXCommandOutputBeforeSleepCompletes() async throws {
        let output = StreamingOutputCapture()
        let shell = try ModelShellProxy()
            .enable(.posixCore)

        let task = Task {
            await shell.run(
                "for i in $(seq 1 2); do echo \"流式输出测试 $i/2 - $(date '+%H:%M:%S')\"; sleep 0.8; done",
                outputStream: output
            )
        }

        let didStreamFirstOutput = await waitUntil(timeoutNanoseconds: 500_000_000) {
            await output.text().contains("流式输出测试 1/2")
        }
        XCTAssertTrue(didStreamFirstOutput)

        let result = await task.value
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("流式输出测试 1/2"))
        XCTAssertTrue(result.stdout.contains("流式输出测试 2/2"))
        let finalOutput = await output.text()
        XCTAssertEqual(finalOutput, result.stdout)
    }

    func testForLoopObservedWcStdinRedirectionCompletesPromptly() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let output = StreamingOutputCapture()
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let setup = await shell.run("printf 'a\n' > /a.txt; printf 'b\nc\n' > /b.txt")
        XCTAssertEqual(setup.stderr, "")
        XCTAssertEqual(setup.exitCode, 0)

        let start = Date()
        let result = await shell.run(
            #"for f in /a.txt /b.txt; do echo -n "$(basename $f) "; wc -l < "$f"; done"#,
            outputStream: output
        )

        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertEqual(result.stdout, "a.txt 1\nb.txt 2\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        let streamedOutput = await output.text()
        XCTAssertEqual(streamedOutput, result.stdout)
    }

    func testForLoopObservedWcStdinRedirectionIgnoresInheritedLiveInput() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let inheritedInput = MSPAsyncBytePipe()
        let output = StreamingOutputCapture()
        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let shell = try ModelShellProxy(configuration: MSPConfiguration(
            workspace: workspace,
            standardInputStream: inheritedInput
        ))
        .enable(.posixCore)

        let setup = await shell.run("printf 'a\n' > /a.txt; printf 'b\nc\n' > /b.txt")
        XCTAssertEqual(setup.stderr, "")
        XCTAssertEqual(setup.exitCode, 0)

        let task = Task {
            await shell.run(
                #"for f in /a.txt /b.txt; do echo -n "$(basename $f) "; wc -l < "$f"; done"#,
                outputStream: output
            )
        }

        let didFinish = await waitUntil(timeoutNanoseconds: 500_000_000) {
            await output.text() == "a.txt 1\nb.txt 2\n"
        }
        if !didFinish {
            await inheritedInput.closeWrite()
        }

        let result = await task.value
        await inheritedInput.closeWrite()

        XCTAssertTrue(didFinish)
        XCTAssertEqual(result.stdout, "a.txt 1\nb.txt 2\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        let streamedOutput = await output.text()
        XCTAssertEqual(streamedOutput, result.stdout)
    }

}
