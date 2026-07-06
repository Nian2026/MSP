import Foundation
import XCTest
import ModelShellProxy
import MSPApple
import MSPAgentBridge
import MSPPythonEmbeddedRuntime

final class MSPPythonEmbeddedRuntimeTests: MSPPythonEmbeddedRuntimeTestCase {
    func testEmbeddedRuntimeReceivesMSPPlannedPythonRequest() async throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
            .enable(.python(runtime: MSPPythonEmbeddedRuntime(engine: EchoEmbeddedPythonEngine())))

        let result = await shell.run("printf 'abc' | python3 -Sc 'print(1)' arg")

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, """
        name=python3
        argv=-Sc|print(1)|arg
        entrypoint=command:print(1):arg
        cwd=/
        pwd=/
        workspace=yes
        stdinBytes=3
        stdinClosed=false
        umask=022

        """)
    }

    func testEmbeddedRuntimePreservesClosedStandardInputState() async throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let configuration = MSPConfiguration(
            workspace: workspace,
            standardInputClosed: true
        )
        let shell = try ModelShellProxy(configuration: configuration)
            .enable(.python(runtime: MSPPythonEmbeddedRuntime(engine: EchoEmbeddedPythonEngine())))

        let result = await shell.run("python3 -")

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("entrypoint=stdin:\n"))
        XCTAssertTrue(result.stdout.contains("stdinBytes=0\n"))
        XCTAssertTrue(result.stdout.contains("stdinClosed=true\n"))
    }

    func testEmbeddedRuntimeStreamingEngineReceivesLiveExecSessionStdin() async throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
            .enable(.python(runtime: MSPPythonEmbeddedRuntime(engine: StreamingEchoEmbeddedPythonEngine())))
        let bridge = shell.execCommandBridge()

        let start = await bridge.runSession(MSPExecCommandCall(
            cmd: "python3 -c 'ignored'",
            yieldTimeMilliseconds: 100
        ))
        let sessionID: Int = try XCTUnwrap(start.runningSessionID)
        XCTAssertTrue(start.result.stdout.contains("READY\n"), start.result.stdout)
        XCTAssertFalse(start.result.stdout.contains("GOT:"), start.result.stdout)

        let final = await bridge.writeStdin(MSPWriteStdinCall(
            sessionID: sessionID,
            chars: "embedded live line\n",
            yieldTimeMilliseconds: 1_000
        ))
        let transcript = start.result.stdout + final.result.stdout

        XCTAssertNil(final.runningSessionID)
        XCTAssertEqual(final.exitCode, 0, transcript)
        XCTAssertEqual(final.result.stderr, "")
        XCTAssertTrue(transcript.contains("GOT:embedded live line\n"), transcript)
    }

    func testEmbeddedRuntimeEngineUnavailableSurfacesAsCommandFailure() async throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.python(runtime: MSPPythonEmbeddedRuntime(engine: UnavailableEmbeddedPythonEngine())))

        let result = await shell.run("python3 -c 'print(1)'")

        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(
            result.stderr,
            "python3: embedded Python engine unavailable: CPython library is not linked\n"
        )
        XCTAssertEqual(result.exitCode, 126)
    }
}
