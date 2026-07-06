import Foundation
import XCTest
import ModelShellProxy
@testable import MSPPythonRuntime

final class MSPPythonHostProcessSubprocessShellMatrixTests: MSPPythonRuntimeTestCase {
    #if os(macOS)
    func testHostProcessPythonSubprocessHandlesComplexSyntaxAndLongCommands() async throws {
        let pythonURL = try requireHostPython("host-process Python VFS tests.")
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
            .enable(.python(runtime: MSPPythonHostProcessRuntime(
                executableURL: pythonURL,
                workspaceRootURL: rootURL,
                timeout: 60
            )))

        let result = await shell.run("""
        python3 -S - <<'PY'
        from pathlib import Path
        import os
        import shlex
        import subprocess

        complex_command = (
            "mkdir -p /tmp/complex/out; "
            "printf 'beta\\\\nalpha\\\\nalpha\\\\n' > '/tmp/complex/in file.txt'; "
            "cat '/tmp/complex/in file.txt' | sort | uniq > /tmp/complex/out/uniq.txt; "
            "cat /tmp/complex/out/uniq.txt"
        )
        complex_result = subprocess.run(
            complex_command,
            shell=True,
            capture_output=True,
            text=True,
            check=True,
            timeout=5
        )
        print('complex=' + repr(complex_result.stdout))
        print('complex-file=' + repr(Path('/tmp/complex/out/uniq.txt').read_text(encoding='utf-8')))

        heredoc = "cat > /tmp/complex/here.txt <<'EOF'\\nleft right\\nEOF\\ncat /tmp/complex/here.txt"
        heredoc_result = subprocess.run(
            heredoc,
            shell=True,
            capture_output=True,
            text=True,
            check=True,
            timeout=5
        )
        print('heredoc=' + repr(heredoc_result.stdout))

        xargs_output = os.popen(
            "find /tmp/complex -maxdepth 1 -type f -print0 | "
            "xargs -0 stat -c '%n:%s' | sort"
        ).read()
        print('xargs-stat=' + repr(xargs_output))

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

        large = subprocess.run(
            "seq 1 2048",
            shell=True,
            capture_output=True,
            text=True,
            check=True,
            timeout=5
        )
        large_lines = large.stdout.splitlines()
        print('large-count=%d' % len(large_lines))
        print('large-last=' + large_lines[-1])

        long_args = ['arg%05d' % index for index in range(32768)]
        long_command = "printf '%s\\\\n' " + " ".join(shlex.quote(arg) for arg in long_args)
        print('long-command-bytes=%d' % len(long_command.encode('utf-8')))
        long_command_timeout = 30
        long_result = subprocess.run(
            long_command,
            shell=True,
            capture_output=True,
            text=True,
            check=True,
            timeout=long_command_timeout
        )
        long_lines = long_result.stdout.splitlines()
        print('long-count=%d' % len(long_lines))
        print('long-edges=%s/%s' % (long_lines[0], long_lines[-1]))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, """
        complex='alpha\\nbeta\\n'
        complex-file='alpha\\nbeta\\n'
        heredoc='left right\\n'
        xargs-stat='/tmp/complex/here.txt:11\\n/tmp/complex/in file.txt:17\\n'
        redirect-combo='one\\nTWO\\nerr'
        large-count=2048
        large-last=2048
        long-command-bytes=294925
        long-count=32768
        long-edges=arg00000/arg32767

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("subprocess-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("msp-python-launcher.py"))
    }

    func testHostProcessPythonOsPopenAndSystemUseControlledShellWithoutPathLeaks() async throws {
        let pythonURL = try requireHostPython("host-process Python VFS tests.")
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
            .enable(.python(runtime: MSPPythonHostProcessRuntime(
                executableURL: pythonURL,
                workspaceRootURL: rootURL
            )))

        let result = await shell.run("""
        python3 -S - <<'PY'
        from pathlib import Path
        import os

        Path('/tmp/popen').mkdir(parents=True, exist_ok=True)
        Path('/tmp/popen/a.txt').write_text('alpha', encoding='utf-8')
        Path('/tmp/popen/b.md').write_text('beta', encoding='utf-8')

        find_output = os.popen("find /tmp/popen -maxdepth 1 -type f -print | sort").read()
        print('find=' + repr(find_output))

        stat_output = os.popen("stat -c '%n:%s' /tmp/popen/a.txt").read()
        print('stat=' + repr(stat_output))

        system_code = os.system("printf system-out; printf system-err >&2; printf side > /tmp/popen/system.txt")
        false_code = os.system("false")
        print('system-code=%r' % system_code)
        print('false-code=%r' % false_code)
        print('side=' + Path('/tmp/popen/system.txt').read_text(encoding='utf-8'))
        PY
        """)

        XCTAssertEqual(result.stderr, "system-err")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, """
        find='/tmp/popen/a.txt\\n/tmp/popen/b.md\\n'
        stat='/tmp/popen/a.txt:5\\n'
        system-outsystem-code=0
        false-code=256
        side=side

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("subprocess-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("msp-python-launcher.py"))
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("tmp/popen/system.txt"), encoding: .utf8),
            "side"
        )
    }
    #endif
}
