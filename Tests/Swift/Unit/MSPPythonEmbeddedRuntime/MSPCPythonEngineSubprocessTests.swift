import Foundation
import XCTest
import ModelShellProxy
import MSPApple
import MSPPythonEmbeddedRuntime

final class MSPCPythonEngineSubprocessTests: MSPPythonEmbeddedRuntimeTestCase {
    func testCPythonEngineSubprocessHonorsCommandPackExclusionsWhenLibraryIsAvailable() async throws {
        guard let library = Self.localCPythonLibrary() else {
            throw XCTSkip("Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython subprocess policy test.")
        }
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let engine = try MSPCPythonEngine(
            library: .path(library.libraryURL),
            workspaceRootURL: rootURL,
            pythonHomeURL: library.homeURL
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore(excluding: ["sha256sum"]))
            .enable(.python(runtime: MSPPythonEmbeddedRuntime(engine: engine)))

        let result = await shell.run("""
        python3 - <<'PY'
        import subprocess

        direct = subprocess.run(["sha256sum", "--version"], capture_output=True, text=True)
        shell = subprocess.run("sha256sum --version", shell=True, capture_output=True, text=True)
        find = subprocess.run(["find", "/", "-maxdepth", "0", "-type", "d"], capture_output=True, text=True, check=True)

        print("direct=%d:%r:%r" % (direct.returncode, direct.stdout, direct.stderr))
        print("shell=%d:%r:%r" % (shell.returncode, shell.stdout, shell.stderr))
        print("find=%r" % find.stdout)
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        direct=127:'':'sha256sum: command not found\\n'
        shell=127:'':'sha256sum: command not found\\n'
        find='/\\n'

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("subprocess-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("ios does not support processes"))
    }

    func testCPythonEngineSubprocessRunsVirtualAbsoluteCommandPathsFromWhichWhenLibraryIsAvailable() async throws {
        guard let library = Self.localCPythonLibrary() else {
            throw XCTSkip("Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython executable path subprocess test.")
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
        import shutil
        import subprocess

        find_path = shutil.which("find")
        direct = subprocess.run(
            [find_path, "/", "-maxdepth", "0", "-type", "d"],
            capture_output=True,
            text=True,
            check=True
        )
        explicit = subprocess.run(
            ["/usr/bin/find", "/", "-maxdepth", "0", "-type", "d"],
            capture_output=True,
            text=True,
            check=True
        )
        explicit_bin = subprocess.run(
            ["/bin/find", "/", "-maxdepth", "0", "-type", "d"],
            capture_output=True,
            text=True,
            check=True
        )
        shell = subprocess.run(
            "/usr/bin/find / -maxdepth 0 -type d",
            shell=True,
            capture_output=True,
            text=True,
            check=True
        )
        shell_bin = subprocess.run(
            "/bin/find / -maxdepth 0 -type d",
            shell=True,
            capture_output=True,
            text=True,
            check=True
        )

        print("which=" + find_path)
        print("direct=" + repr(direct.stdout))
        print("explicit=" + repr(explicit.stdout))
        print("explicit-bin=" + repr(explicit_bin.stdout))
        print("shell=" + repr(shell.stdout))
        print("shell-bin=" + repr(shell_bin.stdout))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        which=/usr/bin/find
        direct='/\\n'
        explicit='/\\n'
        explicit-bin='/\\n'
        shell='/\\n'
        shell-bin='/\\n'

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("subprocess-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("ios does not support processes"))
    }

    func testCPythonEngineSubprocessRespectsVirtualPATHEnvironmentWhenLibraryIsAvailable() async throws {
        guard let library = Self.localCPythonLibrary() else {
            throw XCTSkip("Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython subprocess PATH test.")
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
        import subprocess

        hidden = subprocess.run(
            ["find", "/", "-maxdepth", "0", "-type", "d"],
            env={"PATH": "/nope"},
            capture_output=True,
            text=True
        )
        visible = subprocess.run(
            ["find", "/", "-maxdepth", "0", "-type", "d"],
            env={"PATH": "/bin"},
            capture_output=True,
            text=True,
            check=True
        )
        explicit = subprocess.run(
            ["/usr/bin/find", "/", "-maxdepth", "0", "-type", "d"],
            env={"PATH": "/nope"},
            capture_output=True,
            text=True,
            check=True
        )
        shell_hidden = subprocess.run(
            "find / -maxdepth 0 -type d",
            shell=True,
            env={"PATH": "/nope"},
            capture_output=True,
            text=True
        )

        print("hidden=%d:%r:%r" % (hidden.returncode, hidden.stdout, hidden.stderr))
        print("visible=%r" % visible.stdout)
        print("explicit=%r" % explicit.stdout)
        print("shell-hidden=%d:%r:%r" % (shell_hidden.returncode, shell_hidden.stdout, shell_hidden.stderr))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        hidden=127:'':'find: command not found\\n'
        visible='/\\n'
        explicit='/\\n'
        shell-hidden=127:'':'find: command not found\\n'

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("subprocess-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("ios does not support processes"))
    }

    func testCPythonEngineSubprocessPrintenvDoesNotExposeInternalMSPEnvironmentWhenLibraryIsAvailable() async throws {
        guard let library = Self.localCPythonLibrary() else {
            throw XCTSkip("Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython subprocess environment test.")
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
        import subprocess

        env = subprocess.run(["printenv"], capture_output=True, text=True, check=True)
        internal = sorted(line for line in env.stdout.splitlines() if line.startswith("MSP_PYTHON_"))
        print("internal=" + repr(internal))
        print("has-root=" + repr("\(rootURL.path)" in env.stdout))
        print("has-broker=" + repr("vfs-broker" in env.stdout or "subprocess-broker" in env.stdout))
        print("pwd=" + subprocess.check_output(["printenv", "PWD"], text=True).strip())
        print("tmpdir=" + subprocess.check_output(["printenv", "TMPDIR"], text=True).strip())
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        internal=[]
        has-root=False
        has-broker=False
        pwd=/
        tmpdir=/tmp

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("MSP_PYTHON_"))
        XCTAssertFalse((result.stdout + result.stderr).contains("subprocess-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
    }

    func testCPythonEngineNestedPythonSubprocessTracebacksStayVirtualWhenLibraryIsAvailable() async throws {
        guard let library = Self.localCPythonLibrary() else {
            throw XCTSkip("Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython nested traceback test.")
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
        import subprocess

        Path('/tmp').mkdir(exist_ok=True)
        Path('/tmp/child.py').write_text(
            "import sys\\n"
            "print('__file__=' + __file__)\\n"
            "print('argv0=' + sys.argv[0])\\n"
            "raise RuntimeError('embedded child exploded')\\n",
            encoding='utf-8'
        )

        script = subprocess.run(
            ['python3', '-S', '-E', '-I', '/tmp/child.py'],
            capture_output=True,
            text=True,
            timeout=5
        )
        print('script-code=%d' % script.returncode)
        print('script-stdout=' + repr(script.stdout))
        print('script-stderr-virtual=' + repr('File "/tmp/child.py", line 4, in <module>' in script.stderr))
        print('script-stderr-tail=' + script.stderr.splitlines()[-1])

        stdin_child = subprocess.Popen(
            ['python3', '-S', '-'],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        stdin_out, stdin_err = stdin_child.communicate(
            "from pathlib import Path\\n"
            "print('stdin-read=' + Path('/tmp/child.py').read_text(encoding='utf-8').splitlines()[1])\\n"
            "raise RuntimeError('embedded stdin exploded')\\n",
            timeout=5
        )
        print('stdin-code=%d' % stdin_child.returncode)
        print('stdin-stdout=' + repr(stdin_out))
        print('stdin-stderr-virtual=' + repr('File "<stdin>", line 3, in <module>' in stdin_err))
        print('stdin-stderr-tail=' + stdin_err.splitlines()[-1])
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        script-code=1
        script-stdout='__file__=/tmp/child.py\\nargv0=/tmp/child.py\\n'
        script-stderr-virtual=True
        script-stderr-tail=RuntimeError: embedded child exploded
        stdin-code=1
        stdin-stdout="stdin-read=print('__file__=' + __file__)\\n"
        stdin-stderr-virtual=True
        stdin-stderr-tail=RuntimeError: embedded stdin exploded

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("msp-python-launcher.py"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-materialized"))
        XCTAssertFalse((result.stdout + result.stderr).contains("subprocess-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("_msp_vfs"))
        XCTAssertFalse((result.stdout + result.stderr).contains("ios does not support processes"))
    }

    func testCPythonEngineNestedPythonScriptSubprocessUsesVirtualCWDArgumentsAndSiblingFilesWhenLibraryIsAvailable() async throws {
        guard let library = Self.localCPythonLibrary() else {
            throw XCTSkip("Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython nested script test.")
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
        import subprocess

        scripts = Path('/tmp/scripts')
        work = Path('/tmp/work')
        scripts.mkdir(parents=True, exist_ok=True)
        work.mkdir(parents=True, exist_ok=True)
        (scripts / 'sibling.txt').write_text('from-sibling\\n', encoding='utf-8')
        (work / 'relative.txt').write_text('from-cwd\\n', encoding='utf-8')
        (scripts / 'child.py').write_text(
            "from pathlib import Path\\n"
            "import os, sys\\n"
            "print('__file__=' + __file__)\\n"
            "print('argv=' + repr(sys.argv))\\n"
            "print('cwd=' + os.getcwd())\\n"
            "print('path0=' + sys.path[0])\\n"
            "print('sibling=' + Path(__file__).with_name('sibling.txt').read_text(encoding='utf-8').strip())\\n"
            "print('relative=' + Path('relative.txt').read_text(encoding='utf-8').strip())\\n",
            encoding='utf-8'
        )

        child = subprocess.run(
            ['python3', '-S', '-E', '/tmp/scripts/child.py', 'one', 'two'],
            cwd='/tmp/work',
            capture_output=True,
            text=True,
            check=True,
            timeout=5
        )
        print(child.stdout, end='')
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        __file__=/tmp/scripts/child.py
        argv=['/tmp/scripts/child.py', 'one', 'two']
        cwd=/tmp/work
        path0=/tmp/scripts
        sibling=from-sibling
        relative=from-cwd

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("msp-python-launcher.py"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-materialized"))
        XCTAssertFalse((result.stdout + result.stderr).contains("subprocess-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("_msp_vfs"))
        XCTAssertFalse((result.stdout + result.stderr).contains("ios does not support processes"))
    }

    func testCPythonEngineSubprocessTextModeDoesNotSurfaceSurrogateOutputWhenLibraryIsAvailable() async throws {
        guard let library = Self.localCPythonLibrary() else {
            throw XCTSkip("Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython subprocess text decoding test.")
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
        import subprocess

        Path('/tmp').mkdir(exist_ok=True)
        command = r"printf '\\377bad\\n'"
        try:
            subprocess.run(command, shell=True, capture_output=True, text=True, encoding='utf-8')
        except UnicodeDecodeError as error:
            print('default-error=' + error.__class__.__name__)
        else:
            print('default-error=<missing>')

        replaced = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            encoding='utf-8',
            errors='replace'
        )
        print('replace-stdout-escaped=' + replaced.stdout.encode('unicode_escape').decode('ascii'))
        print('replace-has-surrogate=' + repr(any(0xD800 <= ord(ch) <= 0xDFFF for ch in replaced.stdout)))
        Path('/tmp/subprocess-text-report.txt').write_text(replaced.stdout, encoding='utf-8')
        print('report-bytes=' + Path('/tmp/subprocess-text-report.txt').read_bytes().hex())
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        default-error=UnicodeDecodeError
        replace-stdout-escaped=\\ufffdbad\\n
        replace-has-surrogate=False
        report-bytes=efbfbd6261640a

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("subprocess-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("ios does not support processes"))
    }

    func testCPythonEngineSubprocessTextModeDefaultsToUTF8WhenLocaleResolverIsASCIIWhenLibraryIsAvailable() async throws {
        guard let library = Self.localCPythonLibrary() else {
            throw XCTSkip("Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython subprocess UTF-8 text default test.")
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
        import subprocess

        subprocess._text_encoding = lambda: "ascii"
        command = "printf '/相册/系统/截图/33b3a106cdd8.png:\\n'"

        run_result = subprocess.run(
            command,
            shell=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=True
        )
        print("run=" + run_result.stdout.strip())

        check_output = subprocess.check_output(command, shell=True, text=True).strip()
        print("check=" + check_output)

        popen = subprocess.Popen(
            command,
            shell=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        popen_stdout, popen_stderr = popen.communicate(timeout=5)
        print("popen=" + popen_stdout.strip() + "/" + popen_stderr)

        locale_result = subprocess.run(command, shell=True, capture_output=True, encoding="locale", check=True)
        print("locale=" + locale_result.stdout.strip())

        try:
            subprocess.run(command, shell=True, capture_output=True, encoding="ascii", check=True)
        except UnicodeDecodeError as error:
            print("explicit=" + error.encoding)
        else:
            print("explicit=<missing>")
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        run=/相册/系统/截图/33b3a106cdd8.png:
        check=/相册/系统/截图/33b3a106cdd8.png:
        popen=/相册/系统/截图/33b3a106cdd8.png:/
        locale=/相册/系统/截图/33b3a106cdd8.png:
        explicit=ascii

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("subprocess-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("ios does not support processes"))
    }

}
