import Foundation
import XCTest
import ModelShellProxy
import MSPApple
import MSPPythonEmbeddedRuntime

final class MSPCPythonEngineControlledSubprocessMatrixTests: MSPPythonEmbeddedRuntimeTestCase {
    func testCPythonEngineControlledSubprocessPopenMetadataAndPipeModesWhenLibraryIsAvailable() async throws {
        let fixture = try embeddedCPythonShell(
            skipMessage: "Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython controlled subprocess metadata test."
        )
        defer { fixture.cleanup() }

        let result = await fixture.shell.run("""
        python3 - <<'PY'
        import subprocess

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
        print('popen_meta=' + repr((isinstance(p_meta.pid, int), p_meta.pid > 0, p_meta.args, repr(p_meta))))
        print('popen_meta_wait=' + repr((p_meta.wait(timeout=5), repr(p_meta))))

        p_pipe_text = subprocess.Popen(['cat'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        pipe_text_meta = (
            (enc_is_utf8(p_pipe_text.stdin.encoding), p_pipe_text.stdin.errors, p_pipe_text.stdin.newlines, p_pipe_text.stdin.line_buffering, p_pipe_text.stdin.write_through, pipe_methods(p_pipe_text.stdin)),
            (enc_is_utf8(p_pipe_text.stdout.encoding), p_pipe_text.stdout.errors, p_pipe_text.stdout.newlines, p_pipe_text.stdout.line_buffering, p_pipe_text.stdout.write_through, pipe_methods(p_pipe_text.stdout)),
            (enc_is_utf8(p_pipe_text.stderr.encoding), p_pipe_text.stderr.errors, p_pipe_text.stderr.newlines, p_pipe_text.stderr.line_buffering, p_pipe_text.stderr.write_through, pipe_methods(p_pipe_text.stderr)),
        )
        print('pipe_text_meta=' + repr((pipe_text_meta, p_pipe_text.communicate('pipe-meta', timeout=5))))

        p_pipe_bytes = subprocess.Popen(['cat'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        pipe_bytes_meta = (
            (getattr(p_pipe_bytes.stdin, 'encoding', '<missing>'), getattr(p_pipe_bytes.stdin, 'errors', '<missing>'), p_pipe_bytes.stdin.mode, pipe_methods(p_pipe_bytes.stdin)),
            (getattr(p_pipe_bytes.stdout, 'encoding', '<missing>'), getattr(p_pipe_bytes.stdout, 'errors', '<missing>'), p_pipe_bytes.stdout.mode, pipe_methods(p_pipe_bytes.stdout)),
            (getattr(p_pipe_bytes.stderr, 'encoding', '<missing>'), getattr(p_pipe_bytes.stderr, 'errors', '<missing>'), p_pipe_bytes.stderr.mode, pipe_methods(p_pipe_bytes.stderr)),
        )
        print('pipe_bytes_meta=' + repr((pipe_bytes_meta, p_pipe_bytes.communicate(b'bytes-meta', timeout=5))))

        p_stdout_context = subprocess.Popen(['printf', 'ctx'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        with p_stdout_context.stdout as stdout_context:
            stdout_context_same = stdout_context is p_stdout_context.stdout
            stdout_context_read = stdout_context.read()
        print('pipe_stdout_context=' + repr((stdout_context_same, stdout_context_read, p_stdout_context.stdout.closed, p_stdout_context.wait(timeout=5))))

        p_stdin_context = subprocess.Popen(['cat'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        with p_stdin_context.stdin as stdin_context:
            stdin_context_same = stdin_context is p_stdin_context.stdin
            stdin_context_write = stdin_context.write('ctx-in')
        print('pipe_stdin_context=' + repr((stdin_context_same, stdin_context_write, p_stdin_context.stdin.closed, p_stdin_context.stdout.read(), p_stdin_context.wait(timeout=5))))

        p_bytes_context = subprocess.Popen(['printf', 'bctx'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        with p_bytes_context.stdout as bytes_context:
            bytes_context_read = bytes_context.read()
        print('pipe_bytes_context=' + repr((bytes_context_read, p_bytes_context.stdout.closed, p_bytes_context.wait(timeout=5))))

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
        print('popen_context_manager=' + repr(popen_context_cases))

        p_text_settings = subprocess.Popen(['printf', 'meta'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        print('popen_text_settings=' + repr((
            enc_is_utf8(p_text_settings.encoding),
            p_text_settings.errors,
            p_text_settings.text_mode,
            p_text_settings.universal_newlines,
            p_text_settings.communicate(timeout=5)
        )))
        p_errors_settings = subprocess.Popen(['printf', 'meta'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, errors='ignore')
        print('popen_errors_settings=' + repr((
            enc_is_utf8(p_errors_settings.encoding),
            p_errors_settings.errors,
            p_errors_settings.text_mode,
            p_errors_settings.universal_newlines,
            p_errors_settings.communicate(timeout=5)
        )))
        try:
            subprocess.Popen(['true'], text=True, universal_newlines=False)
        except subprocess.SubprocessError as error:
            print('popen_text_conflict=' + repr((error.__class__.__name__, 'Cannot disambiguate' in str(error))))
        try:
            subprocess.run(['true'], text=True, universal_newlines=False)
        except subprocess.SubprocessError as error:
            print('run_text_conflict=' + repr((error.__class__.__name__, 'Cannot disambiguate' in str(error))))
        run_errors_settings = subprocess.run(['printf', 'run-meta'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, errors='ignore')
        print('run_errors_text_mode=' + repr((isinstance(run_errors_settings.stdout, str), run_errors_settings.stdout, run_errors_settings.stderr)))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        popen_meta=(True, True, ['sleep', '0.1'], "<Popen: returncode: None args: ['sleep', '0.1']>")
        popen_meta_wait=(0, "<Popen: returncode: 0 args: ['sleep', '0.1']>")
        pipe_text_meta=(((True, 'strict', None, False, True, (False, True, False, False, True, True)), (True, 'strict', None, False, False, (True, False, False, False, True, True)), (True, 'strict', None, False, False, (True, False, False, False, True, True))), ('pipe-meta', ''))
        pipe_bytes_meta=((('<missing>', '<missing>', 'wb', (False, True, False, False, True, True)), ('<missing>', '<missing>', 'rb', (True, False, False, False, True, True)), ('<missing>', '<missing>', 'rb', (True, False, False, False, True, True))), (b'bytes-meta', b''))
        pipe_stdout_context=(True, 'ctx', True, 0)
        pipe_stdin_context=(True, 6, True, 'ctx-in', 0)
        pipe_bytes_context=(b'bctx', True, 0)
        popen_context_manager=[('true', True, True, True, True, 0), ('late-stdout', True, True, True, True, -13), ('cat', True, True, True, True, -13)]
        popen_text_settings=(True, None, True, True, ('meta', ''))
        popen_errors_settings=(True, 'ignore', 'ignore', 'ignore', ('meta', ''))
        popen_text_conflict=('SubprocessError', True)
        run_text_conflict=('SubprocessError', True)
        run_errors_text_mode=(True, 'run-meta', '')

        """)
        assertNoEmbeddedCPythonHostLeak(result.stdout + result.stderr, rootURL: fixture.rootURL)
    }
}
