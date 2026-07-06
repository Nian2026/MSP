import Foundation
import XCTest
import ModelShellProxy
@testable import MSPPythonRuntime

final class MSPPythonInvocationParsingTests: MSPPythonRuntimeTestCase {
    func testPythonOptionParserMatchesLinuxModuleAndScriptCases() {
        XCTAssertEqual(MSPPythonOptionParser.moduleArgument(in: ["-m", "pip"]), "pip")
        XCTAssertEqual(MSPPythonOptionParser.moduleArgument(in: ["-Im", "pip"]), "pip")
        XCTAssertEqual(MSPPythonOptionParser.moduleArgument(in: ["-Bmpip"]), "pip")
        XCTAssertNil(MSPPythonOptionParser.moduleArgument(in: ["-Wm", "pip"]))
        XCTAssertNil(MSPPythonOptionParser.moduleArgument(in: ["-c", "print(1)", "-mpip"]))

        XCTAssertEqual(MSPPythonOptionParser.scriptArgumentIndex(in: ["-W", "ignore", "/docs/a.py"]), 2)
        XCTAssertEqual(MSPPythonOptionParser.scriptArgumentIndex(in: ["-Xdev", "/docs/a.py"]), 1)
        XCTAssertEqual(MSPPythonOptionParser.scriptArgumentIndex(in: ["-Wm", "pip", "/docs/a.py"]), 1)
        XCTAssertNil(MSPPythonOptionParser.scriptArgumentIndex(in: ["-Im", "pip"]))
        XCTAssertEqual(MSPPythonOptionParser.scriptArgumentIndex(in: ["--", "/docs/a.py"]), 1)
    }

    func testPythonLauncherEntrypointMatchesMSPLauncherCases() async throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data("print('ok')\n".utf8).write(to: rootURL.appendingPathComponent("reader.py"))
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("docs"),
            withIntermediateDirectories: true
        )
        try Data("print('nested')\n".utf8).write(to: rootURL.appendingPathComponent("docs/nested.py"))

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
            .enable(.python(runtime: RecordingPythonRuntime()))

        let noSiteStdin = await shell.run("python3 -S - after")
        let compactCommand = await shell.run("python3 -Sc 'print(1)' arg")
        let module = await shell.run("python3 -Im json.tool data.json")
        let scriptAfterLongOption = await shell.run("python3 --check-hash-based-pycs default reader.py x")
        let scriptAfterDoubleDash = await shell.run("python3 -- docs/nested.py y")
        let interactive = await shell.run("python3 -i -q")

        XCTAssertEqual(noSiteStdin.stdout, "name=python3\nentrypoint=stdin:after\ncwd=/\nstdinBytes=0\n")
        XCTAssertEqual(compactCommand.stdout, "name=python3\nentrypoint=command:print(1):arg\ncwd=/\nstdinBytes=0\n")
        XCTAssertEqual(module.stdout, "name=python3\nentrypoint=module:json.tool:data.json\ncwd=/\nstdinBytes=0\n")
        XCTAssertEqual(scriptAfterLongOption.stdout, "name=python3\nentrypoint=script:/reader.py:x\ncwd=/\nstdinBytes=0\n")
        XCTAssertEqual(scriptAfterDoubleDash.stdout, "name=python3\nentrypoint=script:/docs/nested.py:y\ncwd=/\nstdinBytes=0\n")
        XCTAssertEqual(interactive.stdout, "name=python3\nentrypoint=interactive:\ncwd=/\nstdinBytes=0\n")
    }

    func testPythonMissingTerminalOptionArgumentUsesCommandFailure() async throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.python(runtime: RecordingPythonRuntime()))

        let result = await shell.run("python3 -c")

        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "python3: option -c requires an argument\n")
        XCTAssertEqual(result.exitCode, 1)
    }
}
