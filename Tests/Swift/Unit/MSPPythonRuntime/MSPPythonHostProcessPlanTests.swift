import Foundation
import XCTest
import MSPApple
import MSPCore
@testable import MSPPythonRuntime

final class MSPPythonHostProcessPlanTests: MSPPythonRuntimeTestCase {
    func testHostProcessPlanHonorsUnbufferedInterpreterFlag() throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let launcherURL = rootURL.appendingPathComponent("msp-python-launcher.py")
        let runtime = MSPPythonHostProcessRuntime(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            workspaceRootURL: rootURL
        )
        let request = MSPPythonExecutionRequest(
            invocation: MSPPythonInvocation(
                commandName: "python3",
                arguments: ["-u", "-c", "print('ready')"],
                rawInput: "python3 -u -c \"print('ready')\""
            ),
            entrypoint: .command(source: "print('ready')", arguments: []),
            virtualCurrentDirectory: "/"
        )

        let plan = try runtime.makeProcessPlan(
            for: request,
            context: MSPCommandContext(currentDirectory: "/"),
            launcherURL: launcherURL
        )

        XCTAssertEqual(plan.environment["PYTHONUNBUFFERED"], "1")
        XCTAssertEqual(plan.arguments, [
            "-S",
            launcherURL.path,
            "-u",
            "-c",
            "print('ready')"
        ])
    }

    func testHostProcessPlanIgnoresScriptArgumentNamedLikeUnbufferedFlag() throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let launcherURL = rootURL.appendingPathComponent("msp-python-launcher.py")
        let runtime = MSPPythonHostProcessRuntime(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            workspaceRootURL: rootURL
        )
        let request = MSPPythonExecutionRequest(
            invocation: MSPPythonInvocation(
                commandName: "python3",
                arguments: ["script.py", "-u"],
                rawInput: "python3 script.py -u"
            ),
            entrypoint: .script(
                path: MSPPythonScriptPath(
                    originalOperand: "script.py",
                    virtualPath: "/script.py"
                ),
                arguments: ["-u"]
            ),
            virtualCurrentDirectory: "/"
        )

        let plan = try runtime.makeProcessPlan(
            for: request,
            context: MSPCommandContext(currentDirectory: "/"),
            launcherURL: launcherURL
        )

        XCTAssertNil(plan.environment["PYTHONUNBUFFERED"])
    }

    func testHostProcessRuntimeBuildsMSPStyleLauncherPlanWithoutLeakingVirtualScriptOperand() throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let scriptURL = rootURL.appendingPathComponent("reader.py")
        try Data("print('ok')\n".utf8).write(to: scriptURL)

        let workspace = try MSPAppleWorkspace(rootURL: rootURL)
        let context = MSPCommandContext(
            workspace: workspace,
            currentDirectory: "/",
            environment: ["CUSTOM": "1"],
            standardInput: Data("stdin".utf8)
        )
        let request = MSPPythonExecutionRequest(
            invocation: MSPPythonInvocation(
                commandName: "python3",
                arguments: ["-W", "ignore", "reader.py", "/still-virtual.txt"],
                rawInput: "python3 -W ignore reader.py /still-virtual.txt"
            ),
            entrypoint: .script(
                path: MSPPythonScriptPath(
                    originalOperand: "reader.py",
                    virtualPath: "/reader.py"
                ),
                arguments: ["/still-virtual.txt"]
            ),
            virtualCurrentDirectory: "/"
        )
        let launcherURL = rootURL.appendingPathComponent("msp-python-launcher.py")
        let runtime = MSPPythonHostProcessRuntime(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            workspaceRootURL: rootURL,
            temporaryDirectoryURL: rootURL.appendingPathComponent(".msp-python")
        )

        let plan = try runtime.makeProcessPlan(
            for: request,
            context: context,
            launcherURL: launcherURL
        )

        XCTAssertEqual(plan.executableURL.path, "/usr/bin/python3")
        XCTAssertEqual(plan.arguments, [
            "-S",
            launcherURL.path,
            "-W",
            "ignore",
            "reader.py",
            "/still-virtual.txt"
        ])
        XCTAssertEqual(plan.currentDirectoryURL.standardizedFileURL, rootURL.standardizedFileURL)
        XCTAssertEqual(plan.environment["CUSTOM"], "1")
        XCTAssertEqual(plan.environment["MSP_PYTHON_WORKSPACE_ROOT"], rootURL.standardizedFileURL.path)
        XCTAssertEqual(plan.environment["MSP_PYTHON_VIRTUAL_CWD"], "/")
        XCTAssertEqual(plan.environment["MSP_PYTHON_VIRTUAL_TMPDIR"], "/tmp")
        XCTAssertEqual(plan.environment["MSP_PYTHON_FILE_CREATION_MASK"], "022")
        XCTAssertEqual(plan.environment["PYTHONNOUSERSITE"], "1")
        XCTAssertEqual(plan.environment["PYTHONDONTWRITEBYTECODE"], "1")
        XCTAssertEqual(plan.environment["PYTHONUTF8"], "1")
        XCTAssertEqual(plan.environment["PYTHONIOENCODING"], "utf-8:surrogateescape")
        XCTAssertEqual(plan.standardInput, Data("stdin".utf8))
    }

    func testHostProcessRuntimeLeavesInlineCommandArgumentsUnderLauncherControl() throws {
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let runtime = MSPPythonHostProcessRuntime(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            workspaceRootURL: rootURL
        )
        let request = MSPPythonExecutionRequest(
            invocation: MSPPythonInvocation(
                commandName: "python3",
                arguments: ["-Sc", "print('/reader.py')", "arg"],
                rawInput: "python3 -Sc \"print('/reader.py')\" arg"
            ),
            entrypoint: .command(source: "print('/reader.py')", arguments: ["arg"]),
            virtualCurrentDirectory: "/"
        )
        let launcherURL = rootURL.appendingPathComponent("msp-python-launcher.py")

        let plan = try runtime.makeProcessPlan(
            for: request,
            context: MSPCommandContext(currentDirectory: "/"),
            launcherURL: launcherURL
        )

        XCTAssertEqual(plan.arguments, [
            "-S",
            launcherURL.path,
            "-Sc",
            "print('/reader.py')",
            "arg"
        ])
    }
}
