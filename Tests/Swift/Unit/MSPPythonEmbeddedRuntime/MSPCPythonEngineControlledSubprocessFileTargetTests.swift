import Foundation
import XCTest
import ModelShellProxy
import MSPApple
import MSPPythonEmbeddedRuntime

final class MSPCPythonEngineControlledSubprocessFileTargetTests: MSPPythonEmbeddedRuntimeTestCase {
    func testCPythonEngineControlledSubprocessFileTargetsAndInvalidStreamsWhenLibraryIsAvailable() async throws {
        let fixture = try embeddedCPythonShell(
            skipMessage: "Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython controlled subprocess file target test."
        )
        defer { fixture.cleanup() }

        let result = await fixture.shell.run("""
        python3 - <<'PY'
        import pathlib
        import subprocess
        import time

        with open('/tmp/run-stdout.txt', 'w', encoding='utf-8') as out_file, open('/tmp/run-stderr.txt', 'w', encoding='utf-8') as err_file:
            redirected = subprocess.run(
                "printf file-out; printf file-err >&2; exit 5",
                shell=True,
                stdout=out_file,
                stderr=err_file,
                text=True
            )
        print('run_file_targets=' + repr((
            redirected.returncode,
            redirected.stdout,
            redirected.stderr,
            pathlib.Path('/tmp/run-stdout.txt').read_text(encoding='utf-8'),
            pathlib.Path('/tmp/run-stderr.txt').read_text(encoding='utf-8')
        )))

        with open('/tmp/run-combined.txt', 'w', encoding='utf-8') as combined_file:
            combined_redirect = subprocess.run(
                "printf out; printf err >&2",
                shell=True,
                stdout=combined_file,
                stderr=subprocess.STDOUT,
                text=True
            )
        print('run_combined_file=' + repr((
            combined_redirect.returncode,
            combined_redirect.stdout,
            combined_redirect.stderr,
            pathlib.Path('/tmp/run-combined.txt').read_text(encoding='utf-8')
        )))

        with open('/tmp/run-binary.bin', 'wb') as binary_file:
            binary_redirect = subprocess.run(['printf', 'bin-out'], stdout=binary_file)
        print('run_binary_file=' + repr((
            binary_redirect.returncode,
            binary_redirect.stdout,
            pathlib.Path('/tmp/run-binary.bin').read_bytes()
        )))

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
                print('%s=%r' % (invalid_label, (error.__class__.__name__, pathlib.Path(invalid_path).exists())))
            else:
                print('%s=%r' % (invalid_label, ('NO_ERROR', pathlib.Path(invalid_path).exists())))
        stdout_stdout_cases = [
            ('run-stdout-stdout', lambda path: subprocess.run('printf side > ' + path, shell=True, stdout=subprocess.STDOUT)),
            ('popen-stdout-stdout', lambda path: subprocess.Popen('printf side > ' + path, shell=True, stdout=subprocess.STDOUT)),
        ]
        for stdout_label, stdout_action in stdout_stdout_cases:
            stdout_path = '/tmp/' + stdout_label + '.txt'
            try:
                stdout_action(stdout_path)
            except ValueError as error:
                print('%s=%r' % (stdout_label, (str(error), pathlib.Path(stdout_path).exists())))
            else:
                print('%s=%r' % (stdout_label, ('NO_ERROR', pathlib.Path(stdout_path).exists())))
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
                print('%s=%r' % (stdin_label, (error.__class__.__name__, str(error), pathlib.Path(stdin_path).exists())))
            else:
                print('%s=%r' % (stdin_label, ('NO_ERROR', pathlib.Path(stdin_path).exists())))

        with open('/tmp/popen-wait.txt', 'w', encoding='utf-8') as out_file:
            popen_wait = subprocess.Popen(['printf', 'wait-file'], stdout=out_file, text=True)
            popen_wait_code = popen_wait.wait(timeout=5)
        print('popen_wait_file=' + repr((
            popen_wait_code,
            popen_wait.stdout,
            pathlib.Path('/tmp/popen-wait.txt').read_text(encoding='utf-8')
        )))

        with open('/tmp/popen-stdout.txt', 'w', encoding='utf-8') as out_file, open('/tmp/popen-stderr.txt', 'w', encoding='utf-8') as err_file:
            popen_redirect = subprocess.Popen(
                "printf popen-out; printf popen-err >&2; exit 6",
                shell=True,
                stdout=out_file,
                stderr=err_file,
                text=True
            )
            popen_out, popen_err = popen_redirect.communicate(timeout=5)
        print('popen_file_targets=' + repr((
            popen_redirect.returncode,
            popen_out,
            popen_err,
            popen_redirect.stdout,
            popen_redirect.stderr,
            pathlib.Path('/tmp/popen-stdout.txt').read_text(encoding='utf-8'),
            pathlib.Path('/tmp/popen-stderr.txt').read_text(encoding='utf-8')
        )))

        with open('/tmp/popen-combined.txt', 'w', encoding='utf-8') as combined_file:
            popen_combined = subprocess.Popen(
                "printf out; printf err >&2",
                shell=True,
                stdout=combined_file,
                stderr=subprocess.STDOUT,
                text=True
            )
            popen_combined_result = popen_combined.communicate(timeout=5)
        print('popen_combined_file=' + repr((
            popen_combined.returncode,
            popen_combined_result,
            popen_combined.stdout,
            popen_combined.stderr,
            pathlib.Path('/tmp/popen-combined.txt').read_text(encoding='utf-8')
        )))

        with open('/tmp/popen-binary.bin', 'wb') as binary_file:
            popen_binary = subprocess.Popen(['printf', 'pbin-out'], stdout=binary_file)
            popen_binary_result = popen_binary.communicate(timeout=5)
        print('popen_binary_file=' + repr((
            popen_binary.returncode,
            popen_binary_result,
            popen_binary.stdout,
            pathlib.Path('/tmp/popen-binary.bin').read_bytes()
        )))

        with open('/tmp/popen-poll.txt', 'w', encoding='utf-8') as poll_file:
            popen_poll = subprocess.Popen(['printf', 'poll-file'], stdout=poll_file, text=True)
            popen_poll_code = None
            for _ in range(50):
                popen_poll_code = popen_poll.poll()
                if popen_poll_code is not None:
                    break
                time.sleep(0.02)
        print('popen_poll_file=' + repr((
            popen_poll_code,
            popen_poll.stdout,
            pathlib.Path('/tmp/popen-poll.txt').read_text(encoding='utf-8')
        )))

        with open('/tmp/popen-nested-file.txt', 'w', encoding='utf-8') as nested_file:
            popen_nested_file = subprocess.Popen(
                ['python3', '-c', "print('nested-file-target')"],
                stdout=nested_file,
                text=True
            )
            popen_nested_file_result = popen_nested_file.communicate(timeout=5)
        print('popen_nested_file=' + repr((
            popen_nested_file.returncode,
            popen_nested_file_result,
            popen_nested_file.stdout,
            pathlib.Path('/tmp/popen-nested-file.txt').read_text(encoding='utf-8')
        )))

        with open('/tmp/popen-nested-deferred-file.txt', 'w', encoding='utf-8') as nested_file:
            popen_nested_deferred_file = subprocess.Popen(
                ['python3', '-c', "import sys; print('deferred:' + sys.stdin.read())"],
                stdin=subprocess.PIPE,
                stdout=nested_file,
                text=True
            )
            popen_nested_deferred_result = popen_nested_deferred_file.communicate('payload', timeout=5)
        print('popen_nested_deferred_file=' + repr((
            popen_nested_deferred_file.returncode,
            popen_nested_deferred_result,
            popen_nested_deferred_file.stdout,
            pathlib.Path('/tmp/popen-nested-deferred-file.txt').read_text(encoding='utf-8')
        )))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        run_file_targets=(5, None, None, 'file-out', 'file-err')
        run_combined_file=(0, None, None, 'outerr')
        run_binary_file=(0, None, b'bin-out')
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
        popen_wait_file=(0, None, 'wait-file')
        popen_file_targets=(6, None, None, None, None, 'popen-out', 'popen-err')
        popen_combined_file=(0, (None, None), None, None, 'outerr')
        popen_binary_file=(0, (None, None), None, b'pbin-out')
        popen_poll_file=(0, None, 'poll-file')
        popen_nested_file=(0, (None, None), None, 'nested-file-target\\n')
        popen_nested_deferred_file=(0, (None, None), None, 'deferred:payload\\n')

        """)
        assertNoEmbeddedCPythonHostLeak(result.stdout + result.stderr, rootURL: fixture.rootURL)
    }
}
