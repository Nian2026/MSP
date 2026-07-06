import Foundation
import XCTest
import ModelShellProxy
import MSPApple
import MSPPythonEmbeddedRuntime

final class MSPCPythonEngineSubprocessLifecycleTests: MSPPythonEmbeddedRuntimeTestCase {
    func testCPythonEngineNestedPythonSubprocessDoesNotDeadlockWhenLibraryIsAvailable() async throws {
        guard let library = Self.localCPythonLibrary() else {
            throw XCTSkip("Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython nested subprocess test.")
        }
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let engine = try MSPCPythonEngine(
            library: .path(library.libraryURL),
            workspaceRootURL: rootURL,
            pythonHomeURL: library.homeURL
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
            .enable(.python(runtime: MSPPythonEmbeddedRuntime(engine: engine)))

        let result = await shell.run("""
        python3 - <<'PY'
        import subprocess
        child = subprocess.run(
            ["python3", "-c", "import subprocess; print(subprocess.check_output(['printf', 'nested-child'], text=True))"],
            capture_output=True,
            text=True,
            check=True,
            timeout=5
        )
        print("CHILD=" + repr((child.returncode, child.stdout, child.stderr)))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, "CHILD=(0, 'nested-child\\n', '')\n")
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("ios does not support processes"))

        let shellHeredocResult = await shell.run("""
        python3 - <<'PY'
        import subprocess
        child = subprocess.run(
            "python3 - <<'INNER'\\nprint('inner-here')\\nINNER",
            shell=True,
            capture_output=True,
            text=True,
            check=True,
            timeout=5
        )
        print("HEREDOC=" + repr((child.returncode, child.stdout, child.stderr)))
        PY
        """)

        XCTAssertEqual(shellHeredocResult.stderr, "")
        XCTAssertEqual(shellHeredocResult.exitCode, 0, shellHeredocResult.stderr)
        XCTAssertEqual(shellHeredocResult.stdout, "HEREDOC=(0, 'inner-here\\n', '')\n")
        XCTAssertFalse((shellHeredocResult.stdout + shellHeredocResult.stderr).contains(rootURL.path))
        XCTAssertFalse((shellHeredocResult.stdout + shellHeredocResult.stderr).contains("ios does not support processes"))
    }

    func testCPythonEngineSubprocessTimeoutAndKillCancelSideEffectsWhenLibraryIsAvailable() async throws {
        guard let library = Self.localCPythonLibrary() else {
            throw XCTSkip("Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython cancellation test.")
        }
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let engine = try MSPCPythonEngine(
            library: .path(library.libraryURL),
            workspaceRootURL: rootURL,
            pythonHomeURL: library.homeURL
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
            .enable(.python(runtime: MSPPythonEmbeddedRuntime(engine: engine)))

        let result = await shell.run("""
        python3 - <<'PY'
        from pathlib import Path
        import subprocess
        import time

        root = Path("/tmp/cancel")
        root.mkdir(parents=True, exist_ok=True)
        try:
            subprocess.run(
                "sleep 0.4; printf late > /tmp/cancel/timeout-late.txt",
                shell=True,
                timeout=0.01,
                check=True
            )
        except subprocess.TimeoutExpired as error:
            print("TIMEOUT=" + error.__class__.__name__)
        time.sleep(0.5)
        print("TIMEOUT_FILE=" + str((root / "timeout-late.txt").exists()))

        killed = subprocess.Popen(
            "sleep 0.4; printf late > /tmp/cancel/kill-late.txt",
            shell=True
        )
        time.sleep(0.05)
        killed.kill()
        print("KILL_CODE=%r" % killed.wait(timeout=5))
        time.sleep(0.5)
        print("KILL_FILE=" + str((root / "kill-late.txt").exists()))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        TIMEOUT=TimeoutExpired
        TIMEOUT_FILE=False
        KILL_CODE=-9
        KILL_FILE=False

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("ios does not support processes"))
    }
}
