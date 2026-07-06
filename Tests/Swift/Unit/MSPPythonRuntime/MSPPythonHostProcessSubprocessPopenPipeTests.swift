import Foundation
import XCTest
import ModelShellProxy
@testable import MSPPythonRuntime

extension MSPPythonHostProcessSubprocessTests {
    #if os(macOS)
    func testHostProcessPythonPopenPipeChainsAndNestedPythonUseControlledSubprocessBroker() async throws {
        let pythonURL = try requireHostPython("host-process Python Popen pipe tests.")
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

        Path('/tmp').mkdir(exist_ok=True)

        p2 = subprocess.Popen(['printf', 'pipe-ok'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        out2, err2 = p2.communicate(timeout=5)
        print('p2=%d:%s:%s' % (p2.returncode, out2, err2))

        p3 = subprocess.Popen(
            'printf out; printf err >&2; exit 4',
            shell=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True
        )
        out3, err3 = p3.communicate(timeout=5)
        print('p3=%d:%s:%s' % (p3.returncode, out3, err3))

        sh_list = subprocess.run(['sh', '-c', 'printf sh-list'], capture_output=True, text=True, check=True)
        print('sh-list=' + sh_list.stdout)
        print('call=' + str(subprocess.call(['sh', '-c', 'exit 3'])))
        try:
            subprocess.check_call(['sh', '-c', 'exit 6'])
        except subprocess.CalledProcessError as error:
            print('check-call-error=%r' % (error.returncode,))

        p4 = subprocess.Popen(['cat'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        p4.stdin.write('line1\\n')
        p4.stdin.write('line2\\n')
        p4.stdin.close()
        print('p4-read=' + repr(p4.stdout.read()))
        print('p4-code=%r' % p4.wait(timeout=5))

        p4b = subprocess.Popen(['cat'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        out4b, err4b = p4b.communicate('communicate-input', timeout=5)
        print('communicate-input=%r' % ((p4b.returncode, out4b, err4b),))

        repeat = subprocess.Popen(['printf', 'repeat'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        first_repeat = repeat.communicate(timeout=5)
        second_repeat = repeat.communicate(timeout=5)
        print('communicate-repeat=%r' % ((first_repeat, second_repeat, repeat.returncode),))

        repeat_bytes = subprocess.Popen(['printf', 'brepeat'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        first_repeat_bytes = repeat_bytes.communicate(timeout=5)
        second_repeat_bytes = repeat_bytes.communicate(timeout=5)
        print('communicate-repeat-bytes=%r' % ((first_repeat_bytes, second_repeat_bytes, repeat_bytes.returncode),))

        wait_then_communicate = subprocess.Popen(['printf', 'waited'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        wait_then_code = wait_then_communicate.wait(timeout=5)
        first_wait_communicate = wait_then_communicate.communicate(timeout=5)
        second_wait_communicate = wait_then_communicate.communicate(timeout=5)
        print('communicate-after-wait=%r' % ((wait_then_code, first_wait_communicate, second_wait_communicate, wait_then_communicate.returncode),))

        manual_read_then_communicate = subprocess.Popen(['printf', 'manual'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        manual_read = manual_read_then_communicate.stdout.read()
        first_manual_communicate = manual_read_then_communicate.communicate(timeout=5)
        second_manual_communicate = manual_read_then_communicate.communicate(timeout=5)
        print('communicate-after-manual-read=%r' % ((manual_read, first_manual_communicate, second_manual_communicate, manual_read_then_communicate.returncode),))

        p5 = subprocess.Popen(['printf', 'a\\nb\\n'], stdout=subprocess.PIPE, text=True)
        print('p5-line1=' + p5.stdout.readline().strip())
        print('p5-lines=' + repr(p5.stdout.readlines()))
        print('p5-code=%r' % p5.wait(timeout=5))

        p5_iter = subprocess.Popen(
            "printf 'c\\nd\\n'; printf 'e1\\ne2\\n' >&2",
            shell=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        print('p5-iter-out=' + repr([line for line in p5_iter.stdout]))
        print('p5-iter-err=' + repr([line for line in p5_iter.stderr]))
        print('p5-iter-code=%r' % p5_iter.wait(timeout=5))

        p5_bytes_iter = subprocess.Popen(['printf', 'x\\ny\\n'], stdout=subprocess.PIPE)
        print('p5-bytes-iter=' + repr([line for line in p5_bytes_iter.stdout]))
        print('p5-bytes-code=%r' % p5_bytes_iter.wait(timeout=5))

        p5b_source = subprocess.Popen(['printf', 'delta\\nalpha\\n'], stdout=subprocess.PIPE, text=True)
        p5b_sink = subprocess.run(
            ['sort'],
            stdin=p5b_source.stdout,
            capture_output=True,
            text=True,
            timeout=5,
            check=True
        )
        p5b_source.stdout.close()
        print('run-pipe-chain=%r' % ((p5b_source.wait(timeout=5), p5b_sink.stdout),))

        Path('/tmp/pipe-chain').mkdir(exist_ok=True)
        Path('/tmp/pipe-chain/z.txt').write_text('z\\n', encoding='utf-8')
        Path('/tmp/pipe-chain/a.txt').write_text('a\\n', encoding='utf-8')
        setup_sorter = (
            "mkdir -p /tmp/pipe-bin; "
            "cat > /tmp/pipe-bin/sortpy <<'SORTPY'\\n"
            "#!/usr/bin/python3\\n"
            "import sys\\n"
            "for line in sorted(sys.stdin):\\n"
            "    sys.stdout.write(line)\\n"
            "SORTPY\\n"
            "chmod +x /tmp/pipe-bin/sortpy"
        )
        subprocess.run(setup_sorter, shell=True, capture_output=True, text=True, check=True, timeout=5)
        sorter = Path('/tmp/pipe-bin/sortpy')
        p5c_source = subprocess.Popen(
            ['find', '.', '-maxdepth', '1', '-type', 'f'],
            cwd='/tmp/pipe-chain',
            stdout=subprocess.PIPE,
            text=True
        )
        p5c_sink = subprocess.Popen(
            [str(sorter)],
            cwd='/tmp/pipe-chain',
            stdin=p5c_source.stdout,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        p5c_source.stdout.close()
        out5c, err5c = p5c_sink.communicate(timeout=5)
        print('popen-pipe-chain=%r' % ((p5c_source.wait(timeout=5), p5c_sink.returncode, out5c, err5c),))
        after_pipe = subprocess.run(['python3', '-S', '-c', 'print(789)'], capture_output=True, text=True, check=True)
        print('after-pipe-python=' + after_pipe.stdout.strip())

        devnull = subprocess.run(
            ['printf', 'discard-me'],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5
        )
        print('devnull=%r' % ((devnull.returncode, devnull.stdout, devnull.stderr),))
        print('check-output=' + subprocess.check_output(['printf', 'check-ok'], text=True))

        nested_source = (
            "from pathlib import Path; import os; "
            "print('nested-cwd=' + os.getcwd()); "
            "Path('/tmp/nested.txt').write_text('nested', encoding='utf-8')"
        )
        nested = subprocess.run(['python3', '-c', nested_source], capture_output=True, text=True, check=True)
        print(nested.stdout.strip())
        print('nested-file=' + Path('/tmp/nested.txt').read_text(encoding='utf-8'))

        nested_iter = subprocess.Popen(
            ['python3', '-c', "print('n1'); print('n2')"],
            stdout=subprocess.PIPE,
            text=True
        )
        print('nested-iter=' + repr([line for line in nested_iter.stdout]))
        print('nested-iter-code=%r' % nested_iter.wait(timeout=5))

        nested_repeat = subprocess.Popen(
            ['python3', '-c', "print('nr')"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        first_nested_repeat = nested_repeat.communicate(timeout=5)
        second_nested_repeat = nested_repeat.communicate(timeout=5)
        print('nested-repeat=%r' % ((first_nested_repeat, second_nested_repeat, nested_repeat.returncode),))

        nested_deferred_iter = subprocess.Popen(
            ['python3', '-c', "import sys; print('D:' + sys.stdin.readline().strip()); print('DONE')"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        nested_deferred_iter.stdin.write('deferred\\n')
        nested_deferred_iter.stdin.close()
        print('nested-deferred-iter=' + repr([line for line in nested_deferred_iter.stdout]))
        print('nested-deferred-err=' + repr([line for line in nested_deferred_iter.stderr]))
        print('nested-deferred-code=%r' % nested_deferred_iter.wait(timeout=5))

        nested_deferred_repeat = subprocess.Popen(
            ['python3', '-c', "import sys; print(sys.stdin.read())"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        first_nested_deferred_repeat = nested_deferred_repeat.communicate('dr', timeout=5)
        second_nested_deferred_repeat = nested_deferred_repeat.communicate(timeout=5)
        print('nested-deferred-repeat=%r' % ((first_nested_deferred_repeat, second_nested_deferred_repeat, nested_deferred_repeat.returncode),))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, """
        p2=0:pipe-ok:
        p3=4:outerr:None
        sh-list=sh-list
        call=3
        check-call-error=6
        p4-read='line1\\nline2\\n'
        p4-code=0
        communicate-input=(0, 'communicate-input', '')
        communicate-repeat=(('repeat', ''), ('repeat', ''), 0)
        communicate-repeat-bytes=((b'brepeat', b''), (b'brepeat', b''), 0)
        communicate-after-wait=(0, ('waited', ''), ('waited', ''), 0)
        communicate-after-manual-read=('manual', ('', ''), ('', ''), 0)
        p5-line1=a
        p5-lines=['b\\n']
        p5-code=0
        p5-iter-out=['c\\n', 'd\\n']
        p5-iter-err=['e1\\n', 'e2\\n']
        p5-iter-code=0
        p5-bytes-iter=[b'x\\n', b'y\\n']
        p5-bytes-code=0
        run-pipe-chain=(0, 'alpha\\ndelta\\n')
        popen-pipe-chain=(0, 0, './a.txt\\n./z.txt\\n', '')
        after-pipe-python=789
        devnull=(0, None, None)
        check-output=check-ok
        nested-cwd=/
        nested-file=nested
        nested-iter=['n1\\n', 'n2\\n']
        nested-iter-code=0
        nested-repeat=(('nr\\n', ''), ('nr\\n', ''), 0)
        nested-deferred-iter=['D:deferred\\n', 'DONE\\n']
        nested-deferred-err=[]
        nested-deferred-code=0
        nested-deferred-repeat=(('dr\\n', ''), ('dr\\n', ''), 0)

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("subprocess-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("msp-python-launcher.py"))
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("tmp/nested.txt"), encoding: .utf8),
            "nested"
        )
    }
    #endif
}
