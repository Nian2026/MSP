import Foundation
import XCTest
import ModelShellProxy
import MSPCore
import MSPApple
@testable import MSPPythonRuntime

final class MSPPythonRuntimeTests: MSPPythonRuntimeTestCase {
    func testPythonIsNotRegisteredByPOSIXCoreByDefault() async throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let result = await shell.run("python3 --version")

        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "python3: command not found\n")
        XCTAssertEqual(result.exitCode, 127)
    }

    func testPythonCommandPackRegistersPythonAndPython3OnlyWhenEnabled() async throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
            .enable(.python(runtime: RecordingPythonRuntime()))

        let python = await shell.run("python -c 'print(1)'")
        let python3 = await shell.run("python3 script.py arg")

        XCTAssertEqual(python.stdout, "name=python\nentrypoint=command:print(1):\ncwd=/\nstdinBytes=0\n")
        XCTAssertEqual(python.stderr, "")
        XCTAssertEqual(python.exitCode, 0)
        XCTAssertEqual(python3.stdout, "name=python3\nentrypoint=script:/script.py:arg\ncwd=/\nstdinBytes=0\n")
        XCTAssertEqual(python3.stderr, "")
        XCTAssertEqual(python3.exitCode, 0)
    }

    func testPythonRuntimeReceivesPipelineStandardInput() async throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
            .enable(.python(runtime: RecordingPythonRuntime()))

        let result = await shell.run("printf 'abc' | python3 -c 'import sys'")

        XCTAssertEqual(result.stdout, "name=python3\nentrypoint=command:import sys:\ncwd=/\nstdinBytes=3\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testBufferingStandardInputStreamUsesStreamAsCanonicalInput() async throws {
        let context = MSPCommandContext(
            standardInput: Data("buffer-copy".utf8),
            standardInputStream: MSPDataInputStream(Data("stream-copy".utf8))
        )

        let buffered = try await MSPPythonStreamingRuntimeSupport
            .contextByBufferingStandardInputStream(context)

        XCTAssertEqual(buffered.standardInput, Data("stream-copy".utf8))
        XCTAssertNil(buffered.standardInputStream)
    }
}
