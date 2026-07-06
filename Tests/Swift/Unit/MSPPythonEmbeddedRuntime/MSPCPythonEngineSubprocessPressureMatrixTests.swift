import Foundation
import XCTest
import ModelShellProxy
import MSPApple
import MSPPythonEmbeddedRuntime

final class MSPCPythonEngineSubprocessPressureMatrixTests: MSPPythonEmbeddedRuntimeTestCase {
    func testCPythonEngineSubprocessPopenOsPopenSystemPressureMatrixWhenLibraryIsAvailable() async throws {
        guard let library = Self.localCPythonLibrary() else {
            throw XCTSkip("Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython subprocess pressure test.")
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
        import os
        import shlex
        import subprocess
        import time

        Path("subprocess-input.txt").write_text("from-file\\n")
        Path("subdir").mkdir()
        Path("subdir/inside.txt").write_text("from-cwd\\n")
        run = subprocess.run(["cat", "subprocess-input.txt"], capture_output=True, text=True, check=True)
        print("RUN=" + run.stdout.strip())
        cwd_run = subprocess.run(["cat", "inside.txt"], cwd="subdir", capture_output=True, text=True, check=True)
        print("SUBPROCESS_CWD=" + cwd_run.stdout.strip())
        stdin = subprocess.run(["cat"], input="from-stdin\\n", capture_output=True, text=True, check=True)
        print("STDIN=" + stdin.stdout.strip())
        print("OUTPUT=" + subprocess.check_output(["printf", "%s", "from-printf"], text=True))
        print("CALL=%d" % subprocess.call(["false"]))
        try:
            subprocess.check_call(["false"])
        except subprocess.CalledProcessError as error:
            print("CHECK_CALL=%d" % error.returncode)
        Path("tool.sh").write_text("#!/bin/sh\\nprintf 'tool-out\\n'\\nprintf 'tool-err\\n' >&2\\nexit 6\\n")
        Path("tool.sh").chmod(0o755)
        tool = subprocess.run(["./tool.sh"], capture_output=True, text=True)
        print("TOOL=" + repr((tool.returncode, tool.stdout, tool.stderr)))

        root = Path("/tmp/pressure")
        root.mkdir(parents=True, exist_ok=True)
        (root / "a file.txt").write_text("beta\\nalpha\\nalpha\\n", encoding="utf-8")
        print("CWD=" + os.getcwd())
        print("PATHCWD=" + str(Path.cwd()))

        sorted_result = subprocess.run(
            "cat '/tmp/pressure/a file.txt' | sort | uniq",
            shell=True,
            capture_output=True,
            text=True,
            check=True,
            timeout=5
        )
        print("SORTED=" + repr(sorted_result.stdout))

        cwd_run = subprocess.run(["pwd"], cwd="/tmp/pressure", capture_output=True, text=True, check=True)
        print("PWD=" + cwd_run.stdout.strip())

        p = subprocess.Popen(
            "printf out; printf err >&2; exit 7",
            shell=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True
        )
        out, err = p.communicate(timeout=5)
        print("STDOUT_MERGE=%r" % ((p.returncode, out, err),))

        cat = subprocess.Popen(["cat"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        cat.stdin.write("one\\n")
        cat.stdin.write("two\\n")
        cat.stdin.close()
        print("CAT_LINES=" + repr(cat.stdout.readlines()))
        print("CAT_CODE=%r" % cat.wait(timeout=5))

        incremental = subprocess.Popen(
            "printf A; sleep 0.1; printf B",
            shell=True,
            stdout=subprocess.PIPE,
            text=True
        )
        first = incremental.stdout.read(1)
        rest = incremental.stdout.read()
        print("INCREMENTAL=%r" % ((first, rest, incremental.wait(timeout=5)),))

        stat_output = os.popen(
            "find /tmp/pressure -maxdepth 1 -type f -print0 2>/dev/null | "
            "xargs -0 stat -c '%n:%s' | sort"
        ).read()
        print("POPEN_STAT=" + repr(stat_output))

        system_code = os.system("printf os-out; printf os-err >&2; printf side > /tmp/pressure/system.txt")
        print("SYSTEM=%r" % system_code)
        print("SYSTEM_FILE=" + (root / "system.txt").read_text(encoding="utf-8"))

        long_args = ["arg%04d" % index for index in range(1200)]
        long_command = "printf '%s\\\\n' " + " ".join(shlex.quote(arg) for arg in long_args)
        long_result = subprocess.run(long_command, shell=True, capture_output=True, text=True, check=True, timeout=5)
        long_lines = long_result.stdout.splitlines()
        print("LONG=%d:%s:%s" % (len(long_lines), long_lines[0], long_lines[-1]))
        print("HOST=" + str(root / "a file.txt"))
        PY
        """)

        XCTAssertEqual(result.stderr, "os-err")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        RUN=from-file
        SUBPROCESS_CWD=from-cwd
        STDIN=from-stdin
        OUTPUT=from-printf
        CALL=1
        CHECK_CALL=1
        TOOL=(6, 'tool-out\\n', 'tool-err\\n')
        CWD=/
        PATHCWD=/
        SORTED='alpha\\nbeta\\n'
        PWD=/tmp/pressure
        STDOUT_MERGE=(7, 'outerr', None)
        CAT_LINES=['one\\n', 'two\\n']
        CAT_CODE=0
        INCREMENTAL=('A', 'B', 0)
        POPEN_STAT='/tmp/pressure/a file.txt:17\\n'
        os-outSYSTEM=0
        SYSTEM_FILE=side
        LONG=1200:arg0000:arg1199
        HOST=/tmp/pressure/a file.txt

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("subprocess-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("ios does not support processes"))
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("tmp/pressure/system.txt"), encoding: .utf8),
            "side"
        )
    }
}
