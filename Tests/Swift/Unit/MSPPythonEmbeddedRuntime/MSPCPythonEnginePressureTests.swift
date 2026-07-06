import Foundation
import XCTest
import ModelShellProxy
import MSPApple
import MSPPythonEmbeddedRuntime

final class MSPCPythonEnginePressureTests: MSPPythonEmbeddedRuntimeTestCase {
    func testCPythonEngineComplexSyntaxAndLongCommandPressureWhenLibraryIsAvailable() async throws {
        guard let library = Self.localCPythonLibrary() else {
            throw XCTSkip("Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython complex syntax pressure test.")
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
        import shlex
        import subprocess

        Path('/tmp/complex/out').mkdir(parents=True, exist_ok=True)
        complex_command = (
            "A=ok; "
            "printf 'beta\\\\nalpha\\\\nalpha\\\\n' > '/tmp/complex/in file.txt'; "
            "cat '/tmp/complex/in file.txt' | sort | uniq > /tmp/complex/out/uniq.txt; "
            "test -s /tmp/complex/out/uniq.txt && printf \\\"$A:\\\" || printf bad; "
            "cat /tmp/complex/out/uniq.txt"
        )
        complex_result = subprocess.run(complex_command, shell=True, capture_output=True, text=True, check=True, timeout=5)
        print('complex=' + repr(complex_result.stdout))

        heredoc = "cat > /tmp/complex/here.txt <<'EOF'\\nleft right\\nEOF\\ncat /tmp/complex/here.txt"
        heredoc_result = subprocess.run(heredoc, shell=True, capture_output=True, text=True, check=True, timeout=5)
        print('heredoc=' + repr(heredoc_result.stdout))

        substitution = subprocess.run(
            'printf "%s" "$(printf nested-$(printf value))"',
            shell=True,
            capture_output=True,
            text=True,
            check=True,
            timeout=5
        )
        print('substitution=' + repr(substitution.stdout))

        glob_result = subprocess.run(
            "printf '%s\\n' /tmp/complex/*.txt | sort",
            shell=True,
            capture_output=True,
            text=True,
            check=True,
            timeout=5
        )
        print('glob=' + repr(glob_result.stdout))

        big_output = subprocess.run("seq 1 4096", shell=True, capture_output=True, text=True, check=True, timeout=5)
        big_lines = big_output.stdout.splitlines()
        print('big-output=%d:%s:%s' % (len(big_lines), big_lines[0], big_lines[-1]))

        redirect_combo = subprocess.run(
            "printf 'one\\n' > '/tmp/complex/space file.txt'; "
            "printf 'two\\n' >> '/tmp/complex/space file.txt'; "
            "{ cat < '/tmp/complex/space file.txt'; printf err >&2; } 2>&1 | sed 's/two/TWO/'",
            shell=True,
            capture_output=True,
            text=True,
            check=True,
            timeout=5
        )
        print('redirect-combo=' + repr(redirect_combo.stdout))

        long_args = ['arg%05d' % index for index in range(32768)]
        long_command = "printf '%s\\\\n' " + " ".join(shlex.quote(arg) for arg in long_args)
        print('long-command-bytes=%d' % len(long_command.encode('utf-8')))
        long_result = subprocess.run(long_command, shell=True, capture_output=True, text=True, check=True, timeout=30)
        long_lines = long_result.stdout.splitlines()
        print('long-args=%d:%s:%s' % (len(long_lines), long_lines[0], long_lines[-1]))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        complex='ok:alpha\\nbeta\\n'
        heredoc='left right\\n'
        substitution='nested-value'
        glob='/tmp/complex/here.txt\\n/tmp/complex/in file.txt\\n'
        big-output=4096:1:4096
        redirect-combo='one\\nTWO\\nerr'
        long-command-bytes=294925
        long-args=32768:arg00000:arg32767

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("subprocess-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("ios does not support processes"))
    }
}
