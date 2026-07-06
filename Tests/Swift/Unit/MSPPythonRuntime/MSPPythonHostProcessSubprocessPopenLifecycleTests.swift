import Foundation
import XCTest
import ModelShellProxy
@testable import MSPPythonRuntime

extension MSPPythonHostProcessSubprocessTests {
    #if os(macOS)
    func testHostProcessPythonPopenLifecycleTimeoutsAndConcurrencyUseControlledSubprocessBroker() async throws {
        let pythonURL = try requireHostPython("host-process Python Popen lifecycle tests.")
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
        import signal
        import subprocess
        import threading
        import time

        Path('/tmp').mkdir(exist_ok=True)

        def enc_is_utf8(value):
            return isinstance(value, str) and value.lower().replace('_', '-') == 'utf-8'

        def pipe_methods(stream):
            return (
                stream.readable(),
                stream.writable(),
                stream.seekable(),
                stream.isatty(),
                isinstance(stream.name, int),
                stream.fileno() == stream.name,
            )

        p_meta = subprocess.Popen(['sleep', '0.1'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        print('popen-meta=%r' % ((isinstance(p_meta.pid, int), p_meta.pid > 0, p_meta.args, repr(p_meta)),))
        print('popen-meta-wait=%r' % ((p_meta.wait(timeout=5), repr(p_meta)),))

        p_pipe_text = subprocess.Popen(['cat'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        pipe_text_meta = (
            (enc_is_utf8(p_pipe_text.stdin.encoding), p_pipe_text.stdin.errors, p_pipe_text.stdin.newlines, p_pipe_text.stdin.line_buffering, p_pipe_text.stdin.write_through, pipe_methods(p_pipe_text.stdin)),
            (enc_is_utf8(p_pipe_text.stdout.encoding), p_pipe_text.stdout.errors, p_pipe_text.stdout.newlines, p_pipe_text.stdout.line_buffering, p_pipe_text.stdout.write_through, pipe_methods(p_pipe_text.stdout)),
            (enc_is_utf8(p_pipe_text.stderr.encoding), p_pipe_text.stderr.errors, p_pipe_text.stderr.newlines, p_pipe_text.stderr.line_buffering, p_pipe_text.stderr.write_through, pipe_methods(p_pipe_text.stderr)),
        )
        print('pipe-text-meta=%r' % ((pipe_text_meta, p_pipe_text.communicate('pipe-meta', timeout=5)),))

        p_pipe_bytes = subprocess.Popen(['cat'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        pipe_bytes_meta = (
            (getattr(p_pipe_bytes.stdin, 'encoding', '<missing>'), getattr(p_pipe_bytes.stdin, 'errors', '<missing>'), p_pipe_bytes.stdin.mode, pipe_methods(p_pipe_bytes.stdin)),
            (getattr(p_pipe_bytes.stdout, 'encoding', '<missing>'), getattr(p_pipe_bytes.stdout, 'errors', '<missing>'), p_pipe_bytes.stdout.mode, pipe_methods(p_pipe_bytes.stdout)),
            (getattr(p_pipe_bytes.stderr, 'encoding', '<missing>'), getattr(p_pipe_bytes.stderr, 'errors', '<missing>'), p_pipe_bytes.stderr.mode, pipe_methods(p_pipe_bytes.stderr)),
        )
        print('pipe-bytes-meta=%r' % ((pipe_bytes_meta, p_pipe_bytes.communicate(b'bytes-meta', timeout=5)),))

        p_stdout_context = subprocess.Popen(['printf', 'ctx'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        with p_stdout_context.stdout as stdout_context:
            stdout_context_same = stdout_context is p_stdout_context.stdout
            stdout_context_read = stdout_context.read()
        print('pipe-stdout-context=%r' % ((stdout_context_same, stdout_context_read, p_stdout_context.stdout.closed, p_stdout_context.wait(timeout=5)),))

        p_stdin_context = subprocess.Popen(['cat'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        with p_stdin_context.stdin as stdin_context:
            stdin_context_same = stdin_context is p_stdin_context.stdin
            stdin_context_write = stdin_context.write('ctx-in')
        print('pipe-stdin-context=%r' % ((stdin_context_same, stdin_context_write, p_stdin_context.stdin.closed, p_stdin_context.stdout.read(), p_stdin_context.wait(timeout=5)),))

        p_bytes_context = subprocess.Popen(['printf', 'bctx'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        with p_bytes_context.stdout as bytes_context:
            bytes_context_read = bytes_context.read()
        print('pipe-bytes-context=%r' % ((bytes_context_read, p_bytes_context.stdout.closed, p_bytes_context.wait(timeout=5)),))

        popen_context_cases = []
        for label, command, feed in [
            ('true', ['true'], None),
            ('late-stdout', ['sh', '-c', 'sleep 0.05; printf late'], None),
            ('cat', ['cat'], 'x'),
        ]:
            context_process = subprocess.Popen(
                command,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True
            )
            with context_process as active_process:
                same_process = active_process is context_process
                if feed is not None:
                    active_process.stdin.write(feed)
            popen_context_cases.append((
                label,
                same_process,
                context_process.stdin.closed,
                context_process.stdout.closed,
                context_process.stderr.closed,
                context_process.returncode
            ))
        print('popen-context-manager=%r' % (popen_context_cases,))

        p_text_settings = subprocess.Popen(['printf', 'meta'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        print('popen-text-settings=%r' % ((
            enc_is_utf8(p_text_settings.encoding),
            p_text_settings.errors,
            p_text_settings.text_mode,
            p_text_settings.universal_newlines,
            p_text_settings.communicate(timeout=5)
        ),))
        p_errors_settings = subprocess.Popen(['printf', 'meta'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, errors='ignore')
        print('popen-errors-settings=%r' % ((
            enc_is_utf8(p_errors_settings.encoding),
            p_errors_settings.errors,
            p_errors_settings.text_mode,
            p_errors_settings.universal_newlines,
            p_errors_settings.communicate(timeout=5)
        ),))
        try:
            subprocess.Popen(['true'], text=True, universal_newlines=False)
        except subprocess.SubprocessError as error:
            print('popen-text-conflict=%r' % ((error.__class__.__name__, 'Cannot disambiguate' in str(error)),))
        try:
            subprocess.run(['true'], text=True, universal_newlines=False)
        except subprocess.SubprocessError as error:
            print('run-text-conflict=%r' % ((error.__class__.__name__, 'Cannot disambiguate' in str(error)),))
        run_errors_settings = subprocess.run(['printf', 'run-meta'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, errors='ignore')
        print('run-errors-text-mode=%r' % ((isinstance(run_errors_settings.stdout, str), run_errors_settings.stdout, run_errors_settings.stderr),))

        p_signal = subprocess.Popen(['sleep', '2'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        signal_result = p_signal.send_signal(signal.SIGTERM)
        print('send-signal=%r' % ((signal_result, p_signal.returncode, p_signal.wait(timeout=5), p_signal.returncode),))

        p_done_signal = subprocess.Popen(['printf', 'done'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        p_done_signal.wait(timeout=5)
        done_signal_result = p_done_signal.send_signal(signal.SIGTERM)
        print('send-signal-done=%r' % ((done_signal_result, p_done_signal.returncode),))

        p6 = subprocess.Popen(['sleep', '2'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        print('sleep-poll=' + repr(p6.poll()))
        try:
            p6.wait(timeout=0.01)
        except subprocess.TimeoutExpired as error:
            print('timeout=' + error.__class__.__name__)
        p6.kill()
        print('kill-code=%r' % p6.wait(timeout=5))

        p7 = subprocess.Popen(
            "printf A; sleep 1; printf B",
            shell=True,
            stdout=subprocess.PIPE,
            text=True
        )
        started = time.monotonic()
        first7 = p7.stdout.read(1)
        elapsed7 = time.monotonic() - started
        rest7 = p7.stdout.read()
        print('incremental=%r' % ((first7, rest7, elapsed7 < 0.5, p7.wait(timeout=5)),))

        p8 = subprocess.Popen(
            "printf 'line1\\n'; sleep 0.1; printf 'line2\\n'",
            shell=True,
            stdout=subprocess.PIPE,
            text=True
        )
        print('readline1=' + repr(p8.stdout.readline()))
        print('readline2=' + repr(p8.stdout.readline()))
        print('readline-code=%r' % p8.wait(timeout=5))

        p9 = subprocess.Popen(
            "sleep 0.2; printf slow",
            shell=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        try:
            p9.wait(timeout=0.01)
        except subprocess.TimeoutExpired as error:
            print('timeout-later=' + error.__class__.__name__)
        out9, err9 = p9.communicate(timeout=5)
        print('timeout-communicate=%r' % ((p9.returncode, out9, err9),))

        try:
            subprocess.run(
                "printf O; printf E >&2; sleep 1.0; printf X",
                shell=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=0.2
            )
        except subprocess.TimeoutExpired as error:
            print('run-timeout-output=%r' % ((error.output, error.stdout, error.stderr),))

        try:
            subprocess.run(
                "printf O; printf E >&2; sleep 1.0; printf X",
                shell=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=0.2
            )
        except subprocess.TimeoutExpired as error:
            print('run-timeout-merged=%r' % ((error.output, error.stdout, error.stderr),))

        p9b = subprocess.Popen(
            "printf A; printf Z >&2; sleep 0.2; printf B",
            shell=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        try:
            p9b.communicate(timeout=0.05)
        except subprocess.TimeoutExpired as error:
            print('communicate-timeout-output=%r' % ((error.output, error.stdout, error.stderr, p9b.returncode),))
        print('communicate-timeout-later=%r' % ((p9b.communicate(timeout=5), p9b.returncode),))

        p9c = subprocess.Popen(
            "printf A; printf Z >&2; sleep 0.2; printf B",
            shell=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True
        )
        try:
            p9c.communicate(timeout=0.05)
        except subprocess.TimeoutExpired as error:
            print('communicate-timeout-merged=%r' % ((error.output, error.stdout, error.stderr, p9c.returncode),))
        print('communicate-timeout-merged-later=%r' % ((p9c.communicate(timeout=5), p9c.returncode),))

        try:
            subprocess.run(
                "sleep 0.4; printf late > /tmp/run-timeout-late.txt",
                shell=True,
                timeout=0.01,
                check=True
            )
        except subprocess.TimeoutExpired as error:
            print('run-timeout=' + error.__class__.__name__)
        time.sleep(0.6)
        print('run-timeout-file=' + str(Path('/tmp/run-timeout-late.txt').exists()))

        blocker = threading.Thread(
            target=lambda: subprocess.run("sleep 0.3", shell=True, timeout=5)
        )
        blocker.start()
        time.sleep(0.05)
        try:
            subprocess.run(
                "printf late > /tmp/queued-timeout-late.txt",
                shell=True,
                timeout=0.01,
                check=True
            )
        except subprocess.TimeoutExpired as error:
            print('queued-timeout=' + error.__class__.__name__)
        blocker.join(timeout=5)
        time.sleep(0.4)
        print('queued-timeout-file=' + str(Path('/tmp/queued-timeout-late.txt').exists()))

        p10 = subprocess.Popen(
            "sleep 0.4; printf late > /tmp/kill-late.txt",
            shell=True
        )
        time.sleep(0.05)
        p10.kill()
        print('kill-late-code=%r' % p10.wait(timeout=5))
        time.sleep(0.6)
        print('kill-late-file=' + str(Path('/tmp/kill-late.txt').exists()))

        concurrent = [
            subprocess.Popen("sleep 0.1; printf c1", shell=True, stdout=subprocess.PIPE, text=True),
            subprocess.Popen("printf c2", shell=True, stdout=subprocess.PIPE, text=True),
        ]
        print('concurrent=' + repr(sorted(child.communicate(timeout=5)[0] for child in concurrent)))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, """
        popen-meta=(True, True, ['sleep', '0.1'], "<Popen: returncode: None args: ['sleep', '0.1']>")
        popen-meta-wait=(0, "<Popen: returncode: 0 args: ['sleep', '0.1']>")
        pipe-text-meta=(((True, 'strict', None, False, True, (False, True, False, False, True, True)), (True, 'strict', None, False, False, (True, False, False, False, True, True)), (True, 'strict', None, False, False, (True, False, False, False, True, True))), ('pipe-meta', ''))
        pipe-bytes-meta=((('<missing>', '<missing>', 'wb', (False, True, False, False, True, True)), ('<missing>', '<missing>', 'rb', (True, False, False, False, True, True)), ('<missing>', '<missing>', 'rb', (True, False, False, False, True, True))), (b'bytes-meta', b''))
        pipe-stdout-context=(True, 'ctx', True, 0)
        pipe-stdin-context=(True, 6, True, 'ctx-in', 0)
        pipe-bytes-context=(b'bctx', True, 0)
        popen-context-manager=[('true', True, True, True, True, 0), ('late-stdout', True, True, True, True, -13), ('cat', True, True, True, True, -13)]
        popen-text-settings=(True, None, True, True, ('meta', ''))
        popen-errors-settings=(True, 'ignore', 'ignore', 'ignore', ('meta', ''))
        popen-text-conflict=('SubprocessError', True)
        run-text-conflict=('SubprocessError', True)
        run-errors-text-mode=(True, 'run-meta', '')
        send-signal=(None, None, -15, -15)
        send-signal-done=(None, 0)
        sleep-poll=None
        timeout=TimeoutExpired
        kill-code=-9
        incremental=('A', 'B', True, 0)
        readline1='line1\\n'
        readline2='line2\\n'
        readline-code=0
        timeout-later=TimeoutExpired
        timeout-communicate=(0, 'slow', '')
        run-timeout-output=(b'O', b'O', b'E')
        run-timeout-merged=(b'OE', b'OE', None)
        communicate-timeout-output=(b'A', b'A', b'Z', None)
        communicate-timeout-later=(('AB', 'Z'), 0)
        communicate-timeout-merged=(b'AZ', b'AZ', None, None)
        communicate-timeout-merged-later=(('AZB', None), 0)
        run-timeout=TimeoutExpired
        run-timeout-file=False
        queued-timeout=TimeoutExpired
        queued-timeout-file=False
        kill-late-code=-9
        kill-late-file=False
        concurrent=['c1', 'c2']

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("subprocess-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("msp-python-launcher.py"))
        XCTAssertFalse((result.stdout + result.stderr).contains("_MSPPythonPopen"))
    }
    #endif
}
