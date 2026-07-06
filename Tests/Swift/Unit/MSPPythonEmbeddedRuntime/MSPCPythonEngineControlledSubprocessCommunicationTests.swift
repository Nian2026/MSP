import Foundation
import XCTest
import ModelShellProxy
import MSPApple
import MSPPythonEmbeddedRuntime

final class MSPCPythonEngineControlledSubprocessCommunicationTests: MSPPythonEmbeddedRuntimeTestCase {
    func testCPythonEngineControlledSubprocessRunCommunicateAndPipeChainsWhenLibraryIsAvailable() async throws {
        let fixture = try embeddedCPythonShell(
            skipMessage: "Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython controlled subprocess communication test."
        )
        defer { fixture.cleanup() }

        let result = await fixture.shell.run("""
        mkdir -p /tmp/sub
        python3 - <<'PY'
        import os
        import pathlib
        import subprocess
        import time

        side = pathlib.Path('/tmp/bare.txt')
        p = subprocess.Popen(['sh', '-c', 'printf bare > /tmp/bare.txt'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print('bare_initial_returncode=' + str(p.returncode))
        for _ in range(50):
            if side.exists():
                try:
                    if side.read_text(encoding='utf-8') == 'bare':
                        break
                except FileNotFoundError:
                    pass
            time.sleep(0.02)
        print('bare_file=' + side.read_text(encoding='utf-8'))
        print('bare_wait=' + str(p.wait(timeout=5)))
        print('bare_final_returncode=' + str(p.returncode))

        cp = subprocess.run(['printf', 'run-ok'], capture_output=True, text=True, timeout=5)
        print('run=' + repr((cp.returncode, cp.stdout, cp.stderr)))

        p2 = subprocess.Popen(['printf', 'pipe-ok'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        out2, err2 = p2.communicate(timeout=5)
        print('communicate=' + repr((p2.returncode, out2, err2)))

        p3 = subprocess.Popen(['sh', '-c', 'printf err >&2; printf out'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        out3, err3 = p3.communicate(timeout=5)
        print('stderr_stdout_order=' + repr((p3.returncode, out3, err3)))

        cp3b = subprocess.run('printf err >&2; printf out', shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=5)
        print('run_stderr_stdout_order=' + repr((cp3b.returncode, cp3b.stdout, cp3b.stderr)))

        p4 = subprocess.Popen(['cat'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        out4, err4 = p4.communicate('input-text', timeout=5)
        print('stdin_pipe=' + repr((p4.returncode, out4, err4)))

        p4_repeat = subprocess.Popen(['printf', 'repeat'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        first_repeat = p4_repeat.communicate(timeout=5)
        second_repeat = p4_repeat.communicate(timeout=5)
        print('communicate_repeat=' + repr((first_repeat, second_repeat, p4_repeat.returncode)))

        p4_repeat_bytes = subprocess.Popen(['printf', 'brepeat'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        first_repeat_bytes = p4_repeat_bytes.communicate(timeout=5)
        second_repeat_bytes = p4_repeat_bytes.communicate(timeout=5)
        print('communicate_repeat_bytes=' + repr((first_repeat_bytes, second_repeat_bytes, p4_repeat_bytes.returncode)))

        p4_wait_then_communicate = subprocess.Popen(['printf', 'waited'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        wait_then_code = p4_wait_then_communicate.wait(timeout=5)
        first_wait_communicate = p4_wait_then_communicate.communicate(timeout=5)
        second_wait_communicate = p4_wait_then_communicate.communicate(timeout=5)
        print('communicate_after_wait=' + repr((wait_then_code, first_wait_communicate, second_wait_communicate, p4_wait_then_communicate.returncode)))

        p4_manual_read_then_communicate = subprocess.Popen(['printf', 'manual'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        manual_read = p4_manual_read_then_communicate.stdout.read()
        first_manual_communicate = p4_manual_read_then_communicate.communicate(timeout=5)
        second_manual_communicate = p4_manual_read_then_communicate.communicate(timeout=5)
        print('communicate_after_manual_read=' + repr((manual_read, first_manual_communicate, second_manual_communicate, p4_manual_read_then_communicate.returncode)))

        cp4b = subprocess.run(['cat'], input='run-input', stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=5)
        print('run_input=' + repr((cp4b.returncode, cp4b.stdout, cp4b.stderr)))

        p4b_source = subprocess.Popen(['printf', 'delta\\nalpha\\n'], stdout=subprocess.PIPE, text=True)
        p4b_sink = subprocess.run(
            ['sort'],
            stdin=p4b_source.stdout,
            capture_output=True,
            text=True,
            timeout=5,
            check=True
        )
        p4b_source.stdout.close()
        print('run_pipe_chain=' + repr((p4b_source.wait(timeout=5), p4b_sink.stdout)))

        pathlib.Path('/tmp/pipe-chain').mkdir(exist_ok=True)
        pathlib.Path('/tmp/pipe-chain/z.txt').write_text('z\\n', encoding='utf-8')
        pathlib.Path('/tmp/pipe-chain/a.txt').write_text('a\\n', encoding='utf-8')
        p4b_find = subprocess.Popen(
            ['find', '.', '-maxdepth', '1', '-type', 'f'],
            cwd='/tmp/pipe-chain',
            stdout=subprocess.PIPE,
            text=True
        )
        p4b_sort = subprocess.Popen(
            ['sort'],
            cwd='/tmp/pipe-chain',
            stdin=p4b_find.stdout,
            stdout=subprocess.PIPE,
            text=True
        )
        p4b_find.stdout.close()
        out4b_sort, err4b_sort = p4b_sort.communicate(timeout=5)
        print('popen_pipe_chain=' + repr((p4b_find.wait(timeout=5), p4b_sort.returncode, out4b_sort, err4b_sort)))

        p4c = subprocess.Popen(['cat'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        p4c.stdin.write('pipe-write')
        p4c.stdin.close()
        print('stdin_write_wait=' + str(p4c.wait(timeout=5)))
        print('stdin_write_read=' + p4c.stdout.read())

        p4d = subprocess.Popen(['printf', 'fallback-started'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        first4d = p4d.stdout.read(8)
        rest4d = p4d.stdout.read()
        print('fallback_stdin_pipe_output=' + repr((first4d, rest4d, p4d.wait(timeout=5))))

        p4e = subprocess.Popen('printf shell-fallback', shell=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        print('shell_fallback_stdin_pipe=' + repr((p4e.stdout.read(5), p4e.stdout.read(), p4e.wait(timeout=5))))

        p4f = subprocess.Popen(['cat'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            p4f.wait(timeout=0.05)
        except subprocess.TimeoutExpired as exc:
            print('fallback_open_stdin_timeout=' + exc.__class__.__name__)
        p4f.stdin.write('late')
        p4f.stdin.close()
        print('fallback_open_stdin_later=' + repr((p4f.stdout.read(), p4f.wait(timeout=5))))

        cp5 = subprocess.run(
            'printf shell:$XYZ:$(pwd)',
            shell=True,
            cwd='/tmp/sub',
            env={'XYZ': 'ENVOK', 'PATH': os.environ.get('PATH', '')},
            capture_output=True,
            text=True
        )
        print('shell_cwd_env=' + repr((cp5.returncode, cp5.stdout, cp5.stderr)))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        bare_initial_returncode=None
        bare_file=bare
        bare_wait=0
        bare_final_returncode=0
        run=(0, 'run-ok', '')
        communicate=(0, 'pipe-ok', '')
        stderr_stdout_order=(0, 'errout', None)
        run_stderr_stdout_order=(0, 'errout', None)
        stdin_pipe=(0, 'input-text', '')
        communicate_repeat=(('repeat', ''), ('repeat', ''), 0)
        communicate_repeat_bytes=((b'brepeat', b''), (b'brepeat', b''), 0)
        communicate_after_wait=(0, ('waited', ''), ('waited', ''), 0)
        communicate_after_manual_read=('manual', ('', ''), ('', ''), 0)
        run_input=(0, 'run-input', '')
        run_pipe_chain=(0, 'alpha\\ndelta\\n')
        popen_pipe_chain=(0, 0, './a.txt\\n./z.txt\\n', None)
        stdin_write_wait=0
        stdin_write_read=pipe-write
        fallback_stdin_pipe_output=('fallback', '-started', 0)
        shell_fallback_stdin_pipe=('shell', '-fallback', 0)
        fallback_open_stdin_timeout=TimeoutExpired
        fallback_open_stdin_later=('late', 0)
        shell_cwd_env=(0, 'shell:ENVOK:/tmp/sub', '')

        """)
        assertNoEmbeddedCPythonHostLeak(result.stdout + result.stderr, rootURL: fixture.rootURL)
    }
}
