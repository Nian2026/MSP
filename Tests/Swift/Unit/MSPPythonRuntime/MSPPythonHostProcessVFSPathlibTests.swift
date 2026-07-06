import Foundation
import XCTest
import ModelShellProxy
@testable import MSPPythonRuntime

#if os(macOS)
extension MSPPythonHostProcessVFSTestsPath {
    func testHostProcessPythonPathlibIterdirStaysVirtual() async throws {
        let pythonURL = try requireHostPython("host-process Python VFS pathlib iterdir test.")
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

        root = Path('/tmp/iter')
        (root / 'nested').mkdir(parents=True, exist_ok=True)
        (root / 'alpha.txt').write_text('alpha', encoding='utf-8')

        abs_entries = sorted(root.iterdir(), key=lambda path: path.name)
        print('abs=' + repr([path.as_posix() for path in abs_entries]))
        print('meta=' + repr([
            (
                path.as_posix(),
                path.name,
                path.is_dir(),
                path.is_file(),
                None if path.is_dir() else path.stat().st_size,
            )
            for path in abs_entries
        ]))
        os.chdir('/tmp')
        rel_entries = sorted(Path('iter').iterdir(), key=lambda path: path.name)
        print('rel=' + repr([path.as_posix() for path in rel_entries]))
        print('leaks=' + str(any(
            fragment in ''.join(str(path) + repr(path) for path in abs_entries + rel_entries)
            for fragment in ['vfs-materialized', 'materialized-', '\(rootURL.path)']
        )))
        try:
            list(Path('/tmp/missing-iter').iterdir())
        except FileNotFoundError as error:
            print('missing=' + (error.filename or '') + '|' + str(error))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        abs=['/tmp/iter/alpha.txt', '/tmp/iter/nested']
        meta=[('/tmp/iter/alpha.txt', 'alpha.txt', False, True, 5), ('/tmp/iter/nested', 'nested', True, False, None)]
        rel=['iter/alpha.txt', 'iter/nested']
        leaks=False
        missing=/tmp/missing-iter|[Errno 2] No such file or directory: '/tmp/missing-iter'

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-materialized"))
    }

    func testHostProcessPythonPathlibMutationsStayVirtual() async throws {
        let pythonURL = try requireHostPython("host-process Python VFS pathlib mutation test.")
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
        import errno
        import os
        import stat

        root = Path('/tmp/pathlib-mutate')
        (root / 'nested').mkdir(parents=True)
        (root / 'a.txt').write_text('alpha', encoding='utf-8')
        print('read=' + (root / 'a.txt').read_text(encoding='utf-8'))

        rename_result = (root / 'a.txt').rename(root / 'b.txt')
        print('rename=' + str(rename_result) + ':' + str((root / 'a.txt').exists()) + ':' + (root / 'b.txt').read_text(encoding='utf-8'))

        (root / 'c.txt').write_text('old', encoding='utf-8')
        replace_result = (root / 'b.txt').replace(root / 'c.txt')
        print('replace=' + str(replace_result) + ':' + str((root / 'b.txt').exists()) + ':' + (root / 'c.txt').read_text(encoding='utf-8'))

        (root / 'touch.txt').touch(mode=0o640)
        print('touch=%03o' % stat.S_IMODE((root / 'touch.txt').stat().st_mode))
        (root / 'c.txt').chmod(0o600)
        print('chmod=%03o' % stat.S_IMODE((root / 'c.txt').stat().st_mode))

        os.chdir('/tmp')
        Path('pathlib-mutate/rel.txt').write_text('rel', encoding='utf-8')
        rel_result = Path('pathlib-mutate/rel.txt').rename('pathlib-mutate/rel2.txt')
        print('rel=' + str(rel_result) + ':' + Path('pathlib-mutate/rel2.txt').read_text(encoding='utf-8'))
        os.chdir('/')

        (root / 'c.txt').unlink()
        print('unlink=' + str((root / 'c.txt').exists()))
        (root / 'nested').rmdir()
        print('rmdir=' + str((root / 'nested').exists()))
        (root / 'nonempty').mkdir()
        (root / 'nonempty' / 'child.txt').write_text('child', encoding='utf-8')
        try:
            (root / 'nonempty').rmdir()
        except OSError as error:
            print('rmdir-nonempty=' + type(error).__name__ + ':' + str(error.errno == errno.ENOTEMPTY) + ':' + (error.filename or ''))
        else:
            print('rmdir-nonempty=allowed')
        (root / 'missing-ok.txt').unlink(missing_ok=True)
        print('missing-ok=ok')

        try:
            (root / 'missing.txt').unlink()
        except FileNotFoundError as error:
            print('missing=' + (error.filename or '') + '|' + str(error))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        read=alpha
        rename=/tmp/pathlib-mutate/b.txt:False:alpha
        replace=/tmp/pathlib-mutate/c.txt:False:alpha
        touch=640
        chmod=600
        rel=pathlib-mutate/rel2.txt:rel
        unlink=False
        rmdir=False
        rmdir-nonempty=OSError:True:/tmp/pathlib-mutate/nonempty
        missing-ok=ok
        missing=/tmp/pathlib-mutate/missing.txt|[Errno 2] No such file or directory: '/tmp/pathlib-mutate/missing.txt'

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-materialized"))
    }
}
#endif
