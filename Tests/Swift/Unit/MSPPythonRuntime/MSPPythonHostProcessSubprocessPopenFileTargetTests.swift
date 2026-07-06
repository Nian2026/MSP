import Foundation
import XCTest
import ModelShellProxy
@testable import MSPPythonRuntime

extension MSPPythonHostProcessSubprocessTests {
    #if os(macOS)
    func testHostProcessPythonPopenFileTargetsAndValidationUseControlledSubprocessBroker() async throws {
        let pythonURL = try requireHostPython("host-process Python Popen file target tests.")
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
        import subprocess
        import time

        bare = subprocess.Popen(
            'printf bare > /tmp/bare.txt',
            shell=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True
        )
        print('bare-code=%r' % bare.wait(timeout=5))
        print('bare-file=' + Path('/tmp/bare.txt').read_text(encoding='utf-8'))

        run = subprocess.run(['printf', 'run-ok'], capture_output=True, text=True, timeout=5)
        print('run=%d:%s:%s' % (run.returncode, run.stdout, run.stderr))

        env = dict(os.environ)
        env['CUSTOM_VALUE'] = 'from-env'
        env_run = subprocess.run(
            ['printenv', 'CUSTOM_VALUE'],
            cwd='/tmp',
            env=env,
            capture_output=True,
            text=True,
            check=True
        )
        cwd_run = subprocess.run(['pwd'], cwd='/tmp', capture_output=True, text=True, check=True)
        print('env=' + env_run.stdout.strip())
        print('cwd-run=' + cwd_run.stdout.strip())

        with open('/tmp/run-stdout.txt', 'w', encoding='utf-8') as out_file, open('/tmp/run-stderr.txt', 'w', encoding='utf-8') as err_file:
            redirected = subprocess.run(
                "printf file-out; printf file-err >&2; exit 5",
                shell=True,
                stdout=out_file,
                stderr=err_file,
                text=True
            )
        print('run-file-targets=%r' % ((
            redirected.returncode,
            redirected.stdout,
            redirected.stderr,
            Path('/tmp/run-stdout.txt').read_text(encoding='utf-8'),
            Path('/tmp/run-stderr.txt').read_text(encoding='utf-8')
        ),))

        with open('/tmp/run-combined.txt', 'w', encoding='utf-8') as combined_file:
            combined_redirect = subprocess.run(
                "printf out; printf err >&2",
                shell=True,
                stdout=combined_file,
                stderr=subprocess.STDOUT,
                text=True
            )
        print('run-combined-file=%r' % ((
            combined_redirect.returncode,
            combined_redirect.stdout,
            combined_redirect.stderr,
            Path('/tmp/run-combined.txt').read_text(encoding='utf-8')
        ),))

        with open('/tmp/run-binary.bin', 'wb') as binary_file:
            binary_redirect = subprocess.run(['printf', 'bin-out'], stdout=binary_file)
        print('run-binary-file=%r' % ((
            binary_redirect.returncode,
            binary_redirect.stdout,
            Path('/tmp/run-binary.bin').read_bytes()
        ),))

        invalid_stream_cases = [
            ('run-bad-stdout', lambda path: subprocess.run('printf side > ' + path, shell=True, stdout=object())),
            ('run-bad-stderr', lambda path: subprocess.run('printf side > ' + path, shell=True, stderr=object())),
            ('popen-bad-stdout', lambda path: subprocess.Popen('printf side > ' + path, shell=True, stdout=object())),
            ('popen-bad-stderr', lambda path: subprocess.Popen('printf side > ' + path, shell=True, stderr=object())),
        ]
        for invalid_label, invalid_action in invalid_stream_cases:
            invalid_path = '/tmp/' + invalid_label + '.txt'
            try:
                invalid_action(invalid_path)
            except ValueError as error:
                print('%s=%r' % (invalid_label, (error.__class__.__name__, Path(invalid_path).exists())))
            else:
                print('%s=%r' % (invalid_label, ('NO_ERROR', Path(invalid_path).exists())))
        stdout_stdout_cases = [
            ('run-stdout-stdout', lambda path: subprocess.run('printf side > ' + path, shell=True, stdout=subprocess.STDOUT)),
            ('popen-stdout-stdout', lambda path: subprocess.Popen('printf side > ' + path, shell=True, stdout=subprocess.STDOUT)),
        ]
        for stdout_label, stdout_action in stdout_stdout_cases:
            stdout_path = '/tmp/' + stdout_label + '.txt'
            try:
                stdout_action(stdout_path)
            except ValueError as error:
                print('%s=%r' % (stdout_label, (str(error), Path(stdout_path).exists())))
            else:
                print('%s=%r' % (stdout_label, ('NO_ERROR', Path(stdout_path).exists())))
        invalid_stdin_cases = [
            ('run-stdin-stdout', lambda path: subprocess.run('printf side > ' + path, shell=True, stdin=subprocess.STDOUT)),
            ('popen-stdin-stdout', lambda path: subprocess.Popen('printf side > ' + path, shell=True, stdin=subprocess.STDOUT)),
            ('run-stdin-object', lambda path: subprocess.run('printf side > ' + path, shell=True, stdin=object())),
            ('popen-stdin-object', lambda path: subprocess.Popen('printf side > ' + path, shell=True, stdin=object())),
            ('run-stdin-fd', lambda path: subprocess.run('printf side > ' + path, shell=True, stdin=5)),
            ('popen-stdin-fd', lambda path: subprocess.Popen('printf side > ' + path, shell=True, stdin=5)),
        ]
        for stdin_label, stdin_action in invalid_stdin_cases:
            stdin_path = '/tmp/' + stdin_label + '.txt'
            try:
                stdin_action(stdin_path)
            except (AttributeError, OSError) as error:
                print('%s=%r' % (stdin_label, (error.__class__.__name__, str(error), Path(stdin_path).exists())))
            else:
                print('%s=%r' % (stdin_label, ('NO_ERROR', Path(stdin_path).exists())))

        with open('/tmp/popen-wait.txt', 'w', encoding='utf-8') as out_file:
            popen_wait = subprocess.Popen(['printf', 'wait-file'], stdout=out_file, text=True)
            popen_wait_code = popen_wait.wait(timeout=5)
        print('popen-wait-file=%r' % ((
            popen_wait_code,
            popen_wait.stdout,
            Path('/tmp/popen-wait.txt').read_text(encoding='utf-8')
        ),))

        with open('/tmp/popen-stdout.txt', 'w', encoding='utf-8') as out_file, open('/tmp/popen-stderr.txt', 'w', encoding='utf-8') as err_file:
            popen_redirect = subprocess.Popen(
                "printf popen-out; printf popen-err >&2; exit 6",
                shell=True,
                stdout=out_file,
                stderr=err_file,
                text=True
            )
            popen_out, popen_err = popen_redirect.communicate(timeout=5)
        print('popen-file-targets=%r' % ((
            popen_redirect.returncode,
            popen_out,
            popen_err,
            popen_redirect.stdout,
            popen_redirect.stderr,
            Path('/tmp/popen-stdout.txt').read_text(encoding='utf-8'),
            Path('/tmp/popen-stderr.txt').read_text(encoding='utf-8')
        ),))

        with open('/tmp/popen-combined.txt', 'w', encoding='utf-8') as combined_file:
            popen_combined = subprocess.Popen(
                "printf out; printf err >&2",
                shell=True,
                stdout=combined_file,
                stderr=subprocess.STDOUT,
                text=True
            )
            popen_combined_result = popen_combined.communicate(timeout=5)
        print('popen-combined-file=%r' % ((
            popen_combined.returncode,
            popen_combined_result,
            popen_combined.stdout,
            popen_combined.stderr,
            Path('/tmp/popen-combined.txt').read_text(encoding='utf-8')
        ),))

        with open('/tmp/popen-binary.bin', 'wb') as binary_file:
            popen_binary = subprocess.Popen(['printf', 'pbin-out'], stdout=binary_file)
            popen_binary_result = popen_binary.communicate(timeout=5)
        print('popen-binary-file=%r' % ((
            popen_binary.returncode,
            popen_binary_result,
            popen_binary.stdout,
            Path('/tmp/popen-binary.bin').read_bytes()
        ),))

        with open('/tmp/popen-poll.txt', 'w', encoding='utf-8') as poll_file:
            popen_poll = subprocess.Popen(['printf', 'poll-file'], stdout=poll_file, text=True)
            popen_poll_code = None
            for _ in range(50):
                popen_poll_code = popen_poll.poll()
                if popen_poll_code is not None:
                    break
                time.sleep(0.02)
        print('popen-poll-file=%r' % ((
            popen_poll_code,
            popen_poll.stdout,
            Path('/tmp/popen-poll.txt').read_text(encoding='utf-8')
        ),))

        with open('/tmp/popen-nested-file.txt', 'w', encoding='utf-8') as nested_file:
            popen_nested_file = subprocess.Popen(
                ['python3', '-c', "print('nested-file-target')"],
                stdout=nested_file,
                text=True
            )
            popen_nested_file_result = popen_nested_file.communicate(timeout=5)
        print('popen-nested-file=%r' % ((
            popen_nested_file.returncode,
            popen_nested_file_result,
            popen_nested_file.stdout,
            Path('/tmp/popen-nested-file.txt').read_text(encoding='utf-8')
        ),))

        with open('/tmp/popen-nested-deferred-file.txt', 'w', encoding='utf-8') as nested_file:
            popen_nested_deferred_file = subprocess.Popen(
                ['python3', '-c', "import sys; print('deferred:' + sys.stdin.read())"],
                stdin=subprocess.PIPE,
                stdout=nested_file,
                text=True
            )
            popen_nested_deferred_result = popen_nested_deferred_file.communicate('payload', timeout=5)
        print('popen-nested-deferred-file=%r' % ((
            popen_nested_deferred_file.returncode,
            popen_nested_deferred_result,
            popen_nested_deferred_file.stdout,
            Path('/tmp/popen-nested-deferred-file.txt').read_text(encoding='utf-8')
        ),))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, """
        bare-code=0
        bare-file=bare
        run=0:run-ok:
        env=from-env
        cwd-run=/tmp
        run-file-targets=(5, None, None, 'file-out', 'file-err')
        run-combined-file=(0, None, None, 'outerr')
        run-binary-file=(0, None, b'bin-out')
        run-bad-stdout=('ValueError', False)
        run-bad-stderr=('ValueError', False)
        popen-bad-stdout=('ValueError', False)
        popen-bad-stderr=('ValueError', False)
        run-stdout-stdout=('STDOUT can only be used for stderr', False)
        popen-stdout-stdout=('STDOUT can only be used for stderr', False)
        run-stdin-stdout=('OSError', '[Errno 9] Bad file descriptor', False)
        popen-stdin-stdout=('OSError', '[Errno 9] Bad file descriptor', False)
        run-stdin-object=('AttributeError', "'object' object has no attribute 'fileno'", False)
        popen-stdin-object=('AttributeError', "'object' object has no attribute 'fileno'", False)
        run-stdin-fd=('OSError', '[Errno 9] Bad file descriptor', False)
        popen-stdin-fd=('OSError', '[Errno 9] Bad file descriptor', False)
        popen-wait-file=(0, None, 'wait-file')
        popen-file-targets=(6, None, None, None, None, 'popen-out', 'popen-err')
        popen-combined-file=(0, (None, None), None, None, 'outerr')
        popen-binary-file=(0, (None, None), None, b'pbin-out')
        popen-poll-file=(0, None, 'poll-file')
        popen-nested-file=(0, (None, None), None, 'nested-file-target\\n')
        popen-nested-deferred-file=(0, (None, None), None, 'deferred:payload\\n')

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("subprocess-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("msp-python-launcher.py"))
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("tmp/bare.txt"), encoding: .utf8),
            "bare"
        )
    }
    #endif
}
