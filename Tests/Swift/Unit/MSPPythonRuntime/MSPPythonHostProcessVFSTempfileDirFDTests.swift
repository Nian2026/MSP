import Foundation
import XCTest
import ModelShellProxy
@testable import MSPPythonRuntime

#if os(macOS)
extension MSPPythonHostProcessVFSTestsBytesAndMetadata {
    func testHostProcessPythonTempfileAndDirFDStayVirtual() async throws {
        let pythonURL = try requireHostPython("host-process Python VFS tests.")
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
            print('dirfd-list=' + ','.join(sorted(os.listdir(dir_fd))))
            print('dirfd-stat=%d' % os.stat('child.txt', dir_fd=dir_fd).st_size)
            print('dirfd-file=' + Path('/tmp/dirfd/child.txt').read_text(encoding='utf-8'))
            os.chmod('child.txt', 0o640, dir_fd=dir_fd)
            print('dirfd-mode=%03o' % stat.S_IMODE(os.stat('child.txt', dir_fd=dir_fd).st_mode))
            os.rename('child.txt', 'renamed.txt', src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
            print('dirfd-renamed=' + Path('/tmp/dirfd/renamed.txt').read_text(encoding='utf-8'))
            os.unlink('renamed.txt', dir_fd=dir_fd)
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

        with tempfile.TemporaryDirectory(dir='/tmp') as temp_dir:
            print('temp-dir-prefix=' + str(temp_dir.startswith('/tmp/')))
            Path(temp_dir, 'note.txt').write_text('note', encoding='utf-8')
            print('temp-dir-read=' + Path(temp_dir, 'note.txt').read_text(encoding='utf-8'))

        print('temp-default-dir=' + tempfile.gettempdir())
        print('temp-default-dir-bytes=' + repr(tempfile.gettempdirb()))
        with tempfile.TemporaryDirectory() as default_temp_dir:
            print('temp-default-prefix=' + str(default_temp_dir.startswith('/tmp/')))
            Path(default_temp_dir, 'default-note.txt').write_text('default-note', encoding='utf-8')
            print('temp-default-read=' + Path(default_temp_dir, 'default-note.txt').read_text(encoding='utf-8'))

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

        temp_fd, temp_name = tempfile.mkstemp(dir='/tmp')
        try:
            print('temp-file-prefix=' + str(temp_name.startswith('/tmp/')))
            os.write(temp_fd, b'temp-data')
        finally:
            os.close(temp_fd)
        print('temp-file-read=' + Path(temp_name).read_text(encoding='utf-8'))
        Path(temp_name).unlink()
        print('tmp-list=' + ','.join(sorted(os.listdir('/tmp'))))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        dirfd-pending-list=child.txt
        dirfd-pending-scandir=child.txt:5
        dirfd-list=child.txt
        dirfd-stat=5
        dirfd-file=child
        dirfd-mode=640
        dirfd-renamed=child
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
        temp-dir-prefix=True
        temp-dir-read=note
        temp-default-dir=/tmp
        temp-default-dir-bytes=b'/tmp'
        temp-default-prefix=True
        temp-default-read=default-note
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
        temp-file-prefix=True
        temp-file-read=temp-data
        tmp-list=dirfd

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-materialized"))
        XCTAssertFalse((result.stdout + result.stderr).contains("subprocess-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("msp-python-launcher.py"))
        XCTAssertEqual(
            try relativeWorkspacePaths(under: rootURL),
            [
                "tmp",
                "tmp/dirfd"
            ]
        )
    }
}
#endif
