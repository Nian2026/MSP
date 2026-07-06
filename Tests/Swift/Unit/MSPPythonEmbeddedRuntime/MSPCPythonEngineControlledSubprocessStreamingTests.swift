import Foundation
import XCTest
import ModelShellProxy
import MSPApple
import MSPPythonEmbeddedRuntime

final class MSPCPythonEngineControlledSubprocessStreamingTests: MSPPythonEmbeddedRuntimeTestCase {
    func testCPythonEngineControlledSubprocessStreamingTimeoutAndNestedPipesWhenLibraryIsAvailable() async throws {
        let fixture = try embeddedCPythonShell(
            skipMessage: "Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython controlled subprocess streaming test."
        )
        defer { fixture.cleanup() }

        let result = await fixture.shell.run("""
        python3 - <<'PY'
        import subprocess
        import time

        p6 = subprocess.Popen(['printf', 'stream-ok'], stdout=subprocess.PIPE, text=True)
        print('stream_read=' + p6.stdout.read())
        print('stream_wait=' + str(p6.wait(timeout=5)))

        p6_iter = subprocess.Popen(
            "printf 'c\\nd\\n'; printf 'e1\\ne2\\n' >&2",
            shell=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        print('stream_iter_out=' + repr([line for line in p6_iter.stdout]))
        print('stream_iter_err=' + repr([line for line in p6_iter.stderr]))
        print('stream_iter_wait=' + str(p6_iter.wait(timeout=5)))

        p6_bytes_iter = subprocess.Popen(['printf', 'x\\ny\\n'], stdout=subprocess.PIPE)
        print('stream_bytes_iter=' + repr([line for line in p6_bytes_iter.stdout]))
        print('stream_bytes_iter_wait=' + str(p6_bytes_iter.wait(timeout=5)))

        cp7 = subprocess.run(['printf', 'discard-me'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True, timeout=5)
        print('devnull=' + repr((cp7.returncode, cp7.stdout, cp7.stderr)))

        print('check_output=' + subprocess.check_output(['printf', 'check-ok'], text=True))
        print('check_output_universal=' + subprocess.check_output(['printf', 'universal-ok'], universal_newlines=True))
        bytes_result = subprocess.run(['printf', 'bytes-ok'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
        print('bytes_run=' + repr((bytes_result.returncode, bytes_result.stdout, bytes_result.stderr)))
        print('call=' + str(subprocess.call(['sh', '-c', 'exit 3'])))
        try:
            subprocess.check_call(['sh', '-c', 'exit 6'])
        except subprocess.CalledProcessError as exc:
            print('check_call_error=' + repr((exc.returncode, exc.cmd)))

        p8 = subprocess.Popen(['cat'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        print('poll_running=' + str(p8.poll()))
        p8.stdin.close()
        print('poll_wait=' + str(p8.wait(timeout=5)))
        print('poll_final=' + str(p8.poll()))

        p9 = subprocess.Popen('sleep 0.2; printf slow', shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            p9.wait(timeout=0.01)
        except subprocess.TimeoutExpired as exc:
            print('timeout_error=' + exc.__class__.__name__)
            print('timeout_cmd=' + repr(exc.cmd))
        out9, err9 = p9.communicate(timeout=5)
        print('timeout_later=' + repr((p9.returncode, out9, err9)))

        try:
            subprocess.run(
                "printf O; printf E >&2; sleep 0.4; printf X",
                shell=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=0.3
            )
        except subprocess.TimeoutExpired as exc:
            print('run_timeout_output=' + repr((exc.output, exc.stdout, exc.stderr)))

        try:
            subprocess.run(
                "printf O; printf E >&2; sleep 0.4; printf X",
                shell=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=0.3
            )
        except subprocess.TimeoutExpired as exc:
            print('run_timeout_merged=' + repr((exc.output, exc.stdout, exc.stderr)))

        p9_partial = subprocess.Popen(
            "printf A; printf Z >&2; sleep 1.0; printf B",
            shell=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        try:
            p9_partial.communicate(timeout=0.3)
        except subprocess.TimeoutExpired as exc:
            print('communicate_timeout_output=' + repr((exc.output, exc.stdout, exc.stderr, p9_partial.returncode)))
        print('communicate_timeout_later=' + repr((p9_partial.communicate(timeout=5), p9_partial.returncode)))

        p9_partial_merged = subprocess.Popen(
            "printf A; printf Z >&2; sleep 1.0; printf B",
            shell=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True
        )
        try:
            p9_partial_merged.communicate(timeout=0.3)
        except subprocess.TimeoutExpired as exc:
            print('communicate_timeout_merged=' + repr((exc.output, exc.stdout, exc.stderr, p9_partial_merged.returncode)))
        print('communicate_timeout_merged_later=' + repr((p9_partial_merged.communicate(timeout=5), p9_partial_merged.returncode)))

        p9b = subprocess.Popen('sleep 0.2; printf communicate-timeout', shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            p9b.communicate(timeout=0.01)
        except subprocess.TimeoutExpired as exc:
            print('communicate_timeout_cmd=' + repr(exc.cmd))
        p9b.kill()
        p9b.wait(timeout=5)

        p10 = subprocess.Popen('printf A; sleep 1.2; printf B', shell=True, stdout=subprocess.PIPE, text=True)
        started = time.monotonic()
        first10 = p10.stdout.read(1)
        elapsed10 = time.monotonic() - started
        rest10 = p10.stdout.read()
        print('incremental_read=' + repr((first10, rest10, elapsed10 < 1.0, p10.wait(timeout=5))))

        p11 = subprocess.Popen("printf 'line1\\n'; sleep 0.1; printf 'line2\\n'", shell=True, stdout=subprocess.PIPE, text=True)
        print('readline1=' + repr(p11.stdout.readline()))
        print('readline2=' + repr(p11.stdout.readline()))
        print('readline_wait=' + str(p11.wait(timeout=5)))

        p11b = subprocess.Popen("printf XYZ; sleep 3; printf '\\n'", shell=True, stdout=subprocess.PIPE, text=True)
        started11b = time.monotonic()
        first11b = p11b.stdout.readline(1)
        elapsed11b = time.monotonic() - started11b
        rest11b = p11b.stdout.read()
        print('readline_size=' + repr((first11b, elapsed11b < 2.5, rest11b, p11b.wait(timeout=10))))

        concurrent = [
            subprocess.Popen(['python3', '-c', 'import time; time.sleep(0.1); print("c1")'], stdout=subprocess.PIPE, text=True),
            subprocess.Popen(['python3', '-c', 'import time; time.sleep(0.05); print("c2")'], stdout=subprocess.PIPE, text=True),
        ]
        print('concurrent=' + repr([child.communicate(timeout=5)[0].strip() for child in concurrent]))

        p11c = subprocess.Popen(['python3', '-c', 'import subprocess,sys; sys.stdout.write(subprocess.check_output(["printf", "nested-child"], text=True))'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        out11c, err11c = p11c.communicate(timeout=5)
        print('nested_bridge=' + repr((p11c.returncode, out11c, err11c)))

        p11d = subprocess.Popen(['python3', '-c', "import sys; data=sys.stdin.read(); print('CHILD:'+data.upper())"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        out11d, err11d = p11d.communicate('abc', timeout=5)
        print('nested_stdin_bridge=' + repr((p11d.returncode, out11d.strip(), err11d)))

        p11e = subprocess.Popen(['python3', '-c', "import sys; data=sys.stdin.read(); print('MANUAL:'+data[::-1])"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        p11e.stdin.write('manual')
        p11e.stdin.close()
        out11e = p11e.stdout.read()
        err11e = p11e.stderr.read()
        print('nested_stdin_manual_read=' + repr((p11e.wait(timeout=5), out11e.strip(), err11e)))

        p11f = subprocess.Popen(['python3', '-c', "print('n1'); print('n2')"], stdout=subprocess.PIPE, text=True)
        print('nested_iter=' + repr([line for line in p11f.stdout]))
        print('nested_iter_wait=' + str(p11f.wait(timeout=5)))

        p11f_repeat = subprocess.Popen(
            ['python3', '-c', "print('nr')"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        first_nested_repeat = p11f_repeat.communicate(timeout=5)
        second_nested_repeat = p11f_repeat.communicate(timeout=5)
        print('nested_repeat=' + repr((first_nested_repeat, second_nested_repeat, p11f_repeat.returncode)))

        p11g = subprocess.Popen(
            ['python3', '-c', "import sys; print('D:' + sys.stdin.readline().strip()); print('DONE')"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        p11g.stdin.write('deferred\\n')
        p11g.stdin.close()
        print('nested_deferred_iter=' + repr([line for line in p11g.stdout]))
        print('nested_deferred_err=' + repr([line for line in p11g.stderr]))
        print('nested_deferred_wait=' + str(p11g.wait(timeout=5)))

        p11g_repeat = subprocess.Popen(
            ['python3', '-c', "import sys; print(sys.stdin.read())"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        first_nested_deferred_repeat = p11g_repeat.communicate('dr', timeout=5)
        second_nested_deferred_repeat = p11g_repeat.communicate(timeout=5)
        print('nested_deferred_repeat=' + repr((first_nested_deferred_repeat, second_nested_deferred_repeat, p11g_repeat.returncode)))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        stream_read=stream-ok
        stream_wait=0
        stream_iter_out=['c\\n', 'd\\n']
        stream_iter_err=['e1\\n', 'e2\\n']
        stream_iter_wait=0
        stream_bytes_iter=[b'x\\n', b'y\\n']
        stream_bytes_iter_wait=0
        devnull=(0, None, None)
        check_output=check-ok
        check_output_universal=universal-ok
        bytes_run=(0, b'bytes-ok', b'')
        call=3
        check_call_error=(6, ['sh', '-c', 'exit 6'])
        poll_running=None
        poll_wait=0
        poll_final=0
        timeout_error=TimeoutExpired
        timeout_cmd='sleep 0.2; printf slow'
        timeout_later=(0, 'slow', '')
        run_timeout_output=(b'O', b'O', b'E')
        run_timeout_merged=(b'OE', b'OE', None)
        communicate_timeout_output=(b'A', b'A', b'Z', None)
        communicate_timeout_later=(('AB', 'Z'), 0)
        communicate_timeout_merged=(b'AZ', b'AZ', None, None)
        communicate_timeout_merged_later=(('AZB', None), 0)
        communicate_timeout_cmd='sleep 0.2; printf communicate-timeout'
        incremental_read=('A', 'B', True, 0)
        readline1='line1\\n'
        readline2='line2\\n'
        readline_wait=0
        readline_size=('X', True, 'YZ\\n', 0)
        concurrent=['c1', 'c2']
        nested_bridge=(0, 'nested-child', '')
        nested_stdin_bridge=(0, 'CHILD:ABC', '')
        nested_stdin_manual_read=(0, 'MANUAL:launam', '')
        nested_iter=['n1\\n', 'n2\\n']
        nested_iter_wait=0
        nested_repeat=(('nr\\n', ''), ('nr\\n', ''), 0)
        nested_deferred_iter=['D:deferred\\n', 'DONE\\n']
        nested_deferred_err=[]
        nested_deferred_wait=0
        nested_deferred_repeat=(('dr\\n', ''), ('dr\\n', ''), 0)

        """)
        assertNoEmbeddedCPythonHostLeak(result.stdout + result.stderr, rootURL: fixture.rootURL)
    }
}
