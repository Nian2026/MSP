import Foundation
import XCTest
import MSPCore
import MSPPythonRuntime
import ModelShellProxy

extension ModelShellProxyScriptExecutionTests {
    func testWorkspaceExecutableShellScriptRunsByPath() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let scriptURL = rootURL.appendingPathComponent("tool.sh")
        try """
        #!/bin/sh
        printf 'tool-out\n'
        printf 'tool-err\n' >&2
        exit 6
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: scriptURL.path
        )

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let result = await shell.run("./tool.sh")

        XCTAssertEqual(result.stdout, "tool-out\n")
        XCTAssertEqual(result.stderr, "tool-err\n")
        XCTAssertEqual(result.exitCode, 6)
    }

    func testWorkspaceExecutablePythonScriptRunsThroughRegisteredPythonCommand() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("scripts"),
            withIntermediateDirectories: true
        )
        let scriptURL = rootURL.appendingPathComponent("scripts/inspect.py")
        try """
        #!/usr/bin/env python3
        print('script')
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: scriptURL.path
        )

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
            .enable(.python(runtime: ScriptExecutionRecordingPythonRuntime()))

        let direct = await shell.run("./scripts/inspect.py alpha 'two words'")
        let piped = await shell.run("printf 'abc' | ./scripts/inspect.py from-pipe")

        XCTAssertEqual(
            direct.stdout,
            "name=python3\nentrypoint=script:/scripts/inspect.py:alpha,two words\ncwd=/\nstdinBytes=0\n"
        )
        XCTAssertEqual(direct.stderr, "")
        XCTAssertEqual(direct.exitCode, 0)
        XCTAssertEqual(
            piped.stdout,
            "name=python3\nentrypoint=script:/scripts/inspect.py:from-pipe\ncwd=/\nstdinBytes=3\n"
        )
        XCTAssertEqual(piped.stderr, "")
        XCTAssertEqual(piped.exitCode, 0)
    }

    func testWorkspaceExecutableShellScriptReportsPathFailuresWithoutHostPaths() async throws {
        let rootURL = makeTemporaryURL()
        defer { removeTemporaryURL(rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("scripts"),
            withIntermediateDirectories: true
        )
        let nonExecutableURL = rootURL.appendingPathComponent("scripts/noexec.sh")
        try "#!/bin/sh\necho noexec\n".write(
            to: nonExecutableURL,
            atomically: true,
            encoding: .utf8
        )
        let unsupportedURL = rootURL.appendingPathComponent("scripts/python")
        try "#!/usr/bin/ruby\nputs 'no'\n".write(
            to: unsupportedURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: unsupportedURL.path
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)

        let directory = await shell.run("./scripts")
        let nonExecutable = await shell.run("./scripts/noexec.sh")
        let unsupported = await shell.run("./scripts/python")

        XCTAssertEqual(directory.stdout, "")
        XCTAssertEqual(directory.stderr, "./scripts: Is a directory\n")
        XCTAssertEqual(directory.exitCode, 126)
        XCTAssertEqual(nonExecutable.stdout, "")
        XCTAssertEqual(nonExecutable.stderr, "./scripts/noexec.sh: Permission denied\n")
        XCTAssertEqual(nonExecutable.exitCode, 126)
        XCTAssertEqual(unsupported.stdout, "")
        XCTAssertEqual(
            unsupported.stderr,
            "./scripts/python: cannot execute: required interpreter is not available\n"
        )
        XCTAssertEqual(unsupported.exitCode, 126)
        XCTAssertFalse(directory.stderr.contains(rootURL.path))
        XCTAssertFalse(nonExecutable.stderr.contains(rootURL.path))
        XCTAssertFalse(unsupported.stderr.contains(rootURL.path))
    }

}

private struct ScriptExecutionRecordingPythonRuntime: MSPPythonRuntime {
    func runPython(
        request: MSPPythonExecutionRequest,
        context: MSPCommandContext
    ) async -> MSPCommandResult {
        .success(stdout: """
        name=\(request.invocation.commandName)
        entrypoint=\(render(request.entrypoint))
        cwd=\(request.virtualCurrentDirectory)
        stdinBytes=\(context.standardInput.count)

        """)
    }

    private func render(_ entrypoint: MSPPythonEntrypoint) -> String {
        switch entrypoint {
        case .command(let source, let arguments):
            return "command:\(source):\(arguments.joined(separator: ","))"
        case .module(let name, let arguments):
            return "module:\(name):\(arguments.joined(separator: ","))"
        case .script(let path, let arguments):
            return "script:\(path.virtualPath):\(arguments.joined(separator: ","))"
        case .standardInput(let arguments):
            return "stdin:\(arguments.joined(separator: ","))"
        case .interactive(let arguments):
            return "interactive:\(arguments.joined(separator: ","))"
        }
    }
}
