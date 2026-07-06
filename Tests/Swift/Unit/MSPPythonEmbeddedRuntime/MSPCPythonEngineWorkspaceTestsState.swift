import Foundation
import XCTest
import ModelShellProxy
import MSPApple
import MSPPythonEmbeddedRuntime

final class MSPCPythonEngineWorkspaceTestsState: MSPPythonEmbeddedRuntimeTestCase {
    func testCPythonEngineTempfileAndDirFDStayVirtualWhenLibraryIsAvailable() async throws {
        guard let library = Self.localCPythonLibrary() else {
            throw XCTSkip("Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython tempfile/dir_fd test.")
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
        import os
        import stat
        import tempfile
        import shutil

        Path('/tmp/dirfd').mkdir(parents=True, exist_ok=True)
        dir_fd = os.open('/tmp/dirfd', os.O_RDONLY | getattr(os, 'O_DIRECTORY', 0))
        try:
            fd = os.open('child.txt', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600, dir_fd=dir_fd)
            os.write(fd, b'child')
            pending_child_entry = next(entry for entry in os.scandir(dir_fd) if entry.name == 'child.txt')
            print('dirfd-pending-list=' + ','.join(sorted(os.listdir(dir_fd))))
            print('dirfd-pending-scandir=' + pending_child_entry.path + ':' + str(pending_child_entry.stat().st_size))
            os.close(fd)
            print('dirfd-file=' + Path('/tmp/dirfd/child.txt').read_text(encoding='utf-8'))
            os.unlink('child.txt', dir_fd=dir_fd)
            rename_fd = os.open('pending-rename.txt', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600, dir_fd=dir_fd)
            os.write(rename_fd, b'dir-moved')
            os.rename('pending-rename.txt', 'pending-renamed.txt', src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
            print('dirfd-pending-rename-list=' + ','.join(sorted(os.listdir(dir_fd))))
            print('dirfd-pending-rename-read=' + Path('/tmp/dirfd/pending-renamed.txt').read_text(encoding='utf-8'))
            os.write(rename_fd, b'-tail')
            os.close(rename_fd)
            print('dirfd-pending-rename-final=' + Path('/tmp/dirfd/pending-renamed.txt').read_text(encoding='utf-8'))
            os.unlink('pending-renamed.txt', dir_fd=dir_fd)
            chmod_fd = os.open('pending-chmod.txt', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600, dir_fd=dir_fd)
            os.write(chmod_fd, b'dir-chmod')
            os.chmod('pending-chmod.txt', 0o641, dir_fd=dir_fd)
            print('dirfd-pending-chmod-before=%03o' % stat.S_IMODE(os.stat('pending-chmod.txt', dir_fd=dir_fd).st_mode))
            print('dirfd-pending-access-rw=' + str(os.access('pending-chmod.txt', os.R_OK | os.W_OK, dir_fd=dir_fd)))
            print('dirfd-pending-access-x=' + str(os.access('pending-chmod.txt', os.X_OK, dir_fd=dir_fd)))
            os.utime('pending-chmod.txt', (2222222222, 2222222222), dir_fd=dir_fd)
            print('dirfd-pending-utime-before=%d' % int(os.stat('pending-chmod.txt', dir_fd=dir_fd).st_mtime))
            os.utime(chmod_fd, (444444444, 444444444))
            print('dirfd-pending-fd-utime-before=%d' % int(os.stat('pending-chmod.txt', dir_fd=dir_fd).st_mtime))
            os.close(chmod_fd)
            print('dirfd-pending-chmod-after=%03o' % stat.S_IMODE(os.stat('pending-chmod.txt', dir_fd=dir_fd).st_mode))
            os.unlink('pending-chmod.txt', dir_fd=dir_fd)
            truncate_fd = os.open('pending-truncate.txt', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600, dir_fd=dir_fd)
            os.write(truncate_fd, b'dir-truncate')
            os.truncate(truncate_fd, 7)
            print('dirfd-pending-truncate-fd=' + Path('/tmp/dirfd/pending-truncate.txt').read_text(encoding='utf-8'))
            os.ftruncate(truncate_fd, 3)
            print('dirfd-pending-ftruncate=' + Path('/tmp/dirfd/pending-truncate.txt').read_text(encoding='utf-8'))
            os.close(truncate_fd)
            print('dirfd-pending-truncate-final=' + Path('/tmp/dirfd/pending-truncate.txt').read_text(encoding='utf-8'))
            os.unlink('pending-truncate.txt', dir_fd=dir_fd)
            print('dirfd-list-after=' + ','.join(sorted(os.listdir(dir_fd))))
        finally:
            os.close(dir_fd)

        print('temp-default-dir=' + tempfile.gettempdir())
        print('temp-default-dir-bytes=' + repr(tempfile.gettempdirb()))
        with tempfile.TemporaryDirectory() as temp_dir:
            print('temp-default-prefix=' + str(temp_dir.startswith('/tmp/')))
            Path(temp_dir, 'note.txt').write_text('note', encoding='utf-8')
            print('temp-default-read=' + Path(temp_dir, 'note.txt').read_text(encoding='utf-8'))

        mkdtemp_dir = tempfile.mkdtemp()
        try:
            print('mkdtemp-prefix=' + str(mkdtemp_dir.startswith('/tmp/')))
            Path(mkdtemp_dir, 'mkd-note.txt').write_text('mkd-note', encoding='utf-8')
            print('mkdtemp-read=' + Path(mkdtemp_dir, 'mkd-note.txt').read_text(encoding='utf-8'))
        finally:
            shutil.rmtree(mkdtemp_dir)

        with tempfile.NamedTemporaryFile(mode='w+', encoding='utf-8') as named_temp:
            print('named-temp-prefix=' + str(named_temp.name.startswith('/tmp/')))
            named_temp.write('named-data')
            named_temp.seek(0)
            print('named-temp-read=' + named_temp.read())

        with tempfile.NamedTemporaryFile(mode='w+', encoding='utf-8', delete=False) as kept_named_temp:
            kept_name = kept_named_temp.name
            print('named-temp-kept-prefix=' + str(kept_name.startswith('/tmp/')))
            kept_named_temp.write('kept-data')
        print('named-temp-kept-read=' + Path(kept_name).read_text(encoding='utf-8'))
        Path(kept_name).unlink()

        with tempfile.TemporaryFile(mode='w+', encoding='utf-8') as temporary_file:
            print('temporary-file-name-type=' + type(temporary_file.name).__name__)
            temporary_file.write('temporary-data')
            temporary_file.seek(0)
            print('temporary-file-read=' + temporary_file.read())

        with tempfile.SpooledTemporaryFile(max_size=2, mode='w+', encoding='utf-8') as spooled_temp:
            print('spooled-temp-name-before=' + repr(getattr(spooled_temp, 'name', None)))
            spooled_temp.write('spooled-data')
            spooled_temp.seek(0)
            print('spooled-temp-read=' + spooled_temp.read())
            print('spooled-temp-rolled=' + str(getattr(spooled_temp, '_rolled', None)))
            print('spooled-temp-name-type-after=' + type(getattr(spooled_temp, 'name', None)).__name__)

        temp_fd, temp_name = tempfile.mkstemp()
        try:
            print('mkstemp-prefix=' + str(temp_name.startswith('/tmp/')))
            os.write(temp_fd, b'temp-data')
        finally:
            os.close(temp_fd)
        print('mkstemp-read=' + Path(temp_name).read_text(encoding='utf-8'))
        Path(temp_name).unlink()
        print('tmp-list=' + ','.join(sorted(os.listdir('/tmp'))))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        dirfd-pending-list=child.txt
        dirfd-pending-scandir=child.txt:5
        dirfd-file=child
        dirfd-pending-rename-list=pending-renamed.txt
        dirfd-pending-rename-read=dir-moved
        dirfd-pending-rename-final=dir-moved-tail
        dirfd-pending-chmod-before=641
        dirfd-pending-access-rw=True
        dirfd-pending-access-x=False
        dirfd-pending-utime-before=2222222222
        dirfd-pending-fd-utime-before=444444444
        dirfd-pending-chmod-after=641
        dirfd-pending-truncate-fd=dir-tru
        dirfd-pending-ftruncate=dir
        dirfd-pending-truncate-final=dir
        dirfd-list-after=
        temp-default-dir=/tmp
        temp-default-dir-bytes=b'/tmp'
        temp-default-prefix=True
        temp-default-read=note
        mkdtemp-prefix=True
        mkdtemp-read=mkd-note
        named-temp-prefix=True
        named-temp-read=named-data
        named-temp-kept-prefix=True
        named-temp-kept-read=kept-data
        temporary-file-name-type=int
        temporary-file-read=temporary-data
        spooled-temp-name-before=None
        spooled-temp-read=spooled-data
        spooled-temp-rolled=True
        spooled-temp-name-type-after=int
        mkstemp-prefix=True
        mkstemp-read=temp-data
        tmp-list=dirfd

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-materialized"))
        XCTAssertFalse((result.stdout + result.stderr).contains("subprocess-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("_msp_vfs"))

        let tmpChildren = try FileManager.default.contentsOfDirectory(
            atPath: rootURL.appendingPathComponent("tmp").path
        )
        XCTAssertEqual(tmpChildren.sorted(), ["dirfd"])
    }
    func testCPythonEngineAppliesVirtualUmaskAndFlushesUnclosedVFSFilesWhenLibraryIsAvailable() async throws {
        guard let library = Self.localCPythonLibrary() else {
            throw XCTSkip("Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython VFS umask/writeback test.")
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
        import json
        import os
        import stat

        root = Path('pyglob')
        (root / 'sub').mkdir(parents=True, exist_ok=True)
        (root / 'a.txt').write_text('A\\n', encoding='utf-8')
        (root / 'sub' / 'b.txt').write_text('BB\\n', encoding='utf-8')
        os.chmod(root / 'sub' / 'b.txt', 0o600)
        leaked = open('payload.bin', 'wb')
        leaked.write(b'PAY\\x00LOAD')
        open('inline.bin', 'wb').write(b'INLINE')

        rows = []
        for path in [root, root / 'sub', root / 'a.txt', root / 'sub' / 'b.txt']:
            path_stat = path.lstat()
            rows.append([
                path.as_posix(),
                oct(stat.S_IMODE(path_stat.st_mode)),
                None if path.is_dir() else path_stat.st_size,
            ])
        print(json.dumps(rows, separators=(',', ':')))

        old_umask = os.umask(0)
        Path('wide-dir').mkdir()
        Path('wide-file.txt').write_text('W', encoding='utf-8')
        wide_dir = oct(stat.S_IMODE(Path('wide-dir').lstat().st_mode))
        wide_file = oct(stat.S_IMODE(Path('wide-file.txt').lstat().st_mode))
        print('old-umask=%03o' % old_umask)
        print('wide=%s/%s' % (wide_dir, wide_file))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        [["pyglob","0o755",null],["pyglob/sub","0o755",null],["pyglob/a.txt","0o644",2],["pyglob/sub/b.txt","0o600",3]]
        old-umask=022
        wide=0o777/0o666

        """)
        XCTAssertEqual(
            try Data(contentsOf: rootURL.appendingPathComponent("payload.bin")),
            Data([0x50, 0x41, 0x59, 0x00, 0x4c, 0x4f, 0x41, 0x44])
        )
        XCTAssertEqual(
            try Data(contentsOf: rootURL.appendingPathComponent("inline.bin")),
            Data("INLINE".utf8)
        )
    }
    func testCPythonEngineTracebackFormatExcStaysVirtualWhenLibraryIsAvailable() async throws {
        guard let library = Self.localCPythonLibrary() else {
            throw XCTSkip("Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython traceback virtualization test.")
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
        import traceback
        try:
            Path('/tmp/missing-dir/file.txt').read_text(encoding='utf-8')
        except Exception:
            text = traceback.format_exc()
            print(text, end='')
        PY
        """)

        let combinedOutput = result.stdout + result.stderr
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("FileNotFoundError"))
        XCTAssertTrue(result.stdout.contains("No such file or directory"))
        XCTAssertTrue(result.stdout.contains("'/tmp/missing-dir/file.txt'"))
        XCTAssertFalse(result.stdout.contains("workspace path not found"))
        XCTAssertTrue(result.stdout.contains(#"File "/usr/lib/python"#))
        XCTAssertFalse(combinedOutput.contains(rootURL.path))
        XCTAssertFalse(combinedOutput.contains("/Users/"))
        XCTAssertFalse(combinedOutput.contains("/private/var"))
        XCTAssertFalse(combinedOutput.contains("/var/containers"))
        XCTAssertFalse(combinedOutput.contains("subprocess-broker"))
        XCTAssertFalse(combinedOutput.contains("vfs-broker"))
        XCTAssertFalse(combinedOutput.contains("CPython"))
        XCTAssertFalse(combinedOutput.contains("ios does not support processes"))
    }
}
