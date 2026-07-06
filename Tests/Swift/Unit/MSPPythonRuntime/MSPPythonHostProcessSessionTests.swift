import Foundation
import XCTest
import ModelShellProxy
import MSPAgentBridge
import MSPApple
import MSPCore
@testable import MSPPythonRuntime

final class MSPPythonHostProcessSessionTests: MSPPythonRuntimeTestCase {
    #if os(macOS)
    func testHostProcessRuntimeInteractiveExecSessionReadsLiveInput() async throws {
        let pythonURL = try requireHostPython("host-process Python interactive tests.")
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
            .enable(.python(runtime: MSPPythonHostProcessRuntime(
                executableURL: pythonURL,
                workspaceRootURL: rootURL,
                temporaryDirectoryURL: rootURL.appendingPathComponent(".msp-python", isDirectory: true)
            )))
        let bridge = shell.execCommandBridge()

        let start = await bridge.runSession(MSPExecCommandCall(
            cmd: "python3 -i -q",
            yieldTimeMilliseconds: 100
        ))
        let sessionID: Int = try XCTUnwrap(start.runningSessionID)
        XCTAssertEqual(start.exitCode, nil)
        XCTAssertEqual(start.result.stderr, "")

        let final = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: "print(\"INTERACTIVE_READY\")\nprint(6 * 7)\nexit()\n",
            yieldTimeMilliseconds: 1_000
        ))
        let transcript = start.result.stdout + final.result.stdout

        XCTAssertNil(final.runningSessionID)
        XCTAssertEqual(final.exitCode, 0, transcript + final.result.stderr)
        XCTAssertEqual(final.result.stderr, "")
        XCTAssertTrue(transcript.contains("INTERACTIVE_READY\n"), transcript)
        XCTAssertTrue(transcript.contains("42\n"), transcript)
    }

    func testHostProcessPythonStreamsOutputBeforeLiveStdinEOF() async throws {
        let pythonURL = try requireHostPython("host-process Python streaming tests.")
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let stdin = MSPAsyncBytePipe()
        let stdout = LivePythonOutputCapture()
        let shell = try ModelShellProxy(configuration: MSPConfiguration(
            workspace: MSPAppleWorkspace(rootURL: rootURL),
            standardInputStream: stdin
        ))
        .enable(.posixCore)
        .enable(.python(runtime: MSPPythonHostProcessRuntime(
            executableURL: pythonURL,
            workspaceRootURL: rootURL
        )))

        let runTask = Task {
            await shell.run(
                """
                python3 -u -c 'import sys; print("READY", flush=True); line=sys.stdin.readline().strip(); print("GOT:" + line, flush=True)'
                """,
                outputStream: stdout
            )
        }

        let sawReady = await stdout.waitUntilContains("READY\n", timeoutNanoseconds: 20_000_000_000)
        let readyTranscript = await stdout.text()
        XCTAssertTrue(sawReady, readyTranscript)
        try await stdin.write(Data("hello\n".utf8))
        await stdin.closeWrite()
        let result = await runTask.value
        let finalTranscript = await stdout.text()

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(finalTranscript, "READY\nGOT:hello\n")
    }
    #endif
}
