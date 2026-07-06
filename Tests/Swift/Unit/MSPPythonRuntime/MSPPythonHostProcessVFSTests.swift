import Foundation
import XCTest
import ModelShellProxy
@testable import MSPPythonRuntime

#if os(macOS)
final class MSPPythonHostProcessVFSTests: MSPPythonRuntimeTestCase {
    func testHostProcessPythonDoesNotMaterializeImplicitTmpAtStartup() async throws {
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
        open('bin.dat', 'wb').write(b'data')
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("bin.dat").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("tmp").path))
    }

    func testHostProcessPythonUsesWorkspaceVirtualFileSystem() async throws {
        let pythonURL = try requireHostPython("host-process Python VFS tests.")
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
            .enable(.python(runtime: MSPPythonHostProcessRuntime(
                executableURL: pythonURL,
                workspaceRootURL: rootURL
            )))

        let pipedInput = await shell.run(
            "printf 'pipe-data' | python3 -S -E -I -c 'import sys; print(sys.stdin.read())'"
        )

        XCTAssertEqual(pipedInput.stdout, "pipe-data\n")
        XCTAssertEqual(pipedInput.stderr, "")
        XCTAssertEqual(pipedInput.exitCode, 0)

        let result = await shell.run("""
        python3 -S - <<'PY'
        from pathlib import Path
        import os
        import shutil
        import stat
        import sys

        Path('/tmp').mkdir(exist_ok=True)
        Path('/tmp/a.txt').write_text('hello\\n', encoding='utf-8')
        print('cwd=' + os.getcwd())
        print('tmpdir=' + os.environ.get('TMPDIR', ''))
        print('internal-env=' + ','.join(sorted(key for key in os.environ if key.startswith('MSP_PYTHON_'))))
        print('read=' + open('/tmp/a.txt', encoding='utf-8').read().strip())
        print('list=' + ','.join(sorted(os.listdir('/tmp'))))
        print('exists=' + str(Path('/tmp/a.txt').exists()))
        abs_entry = next(entry for entry in os.scandir('/tmp') if entry.name == 'a.txt')
        abs_entry_text = abs_entry.path + repr(abs_entry) + os.fspath(abs_entry)
        print('scandir-abs-path=' + abs_entry.path)
        print('scandir-abs-fspath=' + os.fspath(abs_entry))
        print('scandir-abs-repr=' + repr(abs_entry))
        print('scandir-abs-leaks=' + str(any(fragment in abs_entry_text for fragment in ['vfs-materialized', 'materialized-', '\(rootURL.path)'])))
        rel_entry = next(entry for entry in os.scandir('tmp') if entry.name == 'a.txt')
        print('scandir-rel-path=' + rel_entry.path)
        dot_entry = next(entry for entry in os.scandir('.') if entry.name == 'tmp')
        print('scandir-dot-path=' + dot_entry.path)
        abs_file = open('/tmp/a.txt', encoding='utf-8')
        abs_repr = repr(abs_file)
        print('file-name-abs=' + abs_file.name)
        print('file-repr-abs=' + str("name='/tmp/a.txt'" in abs_repr))
        print('file-repr-abs-leaks=' + str(any(fragment in abs_repr for fragment in ['vfs-materialized', 'materialized-', '\(rootURL.path)'])))
        abs_buffer_text = abs_file.buffer.name + abs_file.buffer.raw.name + repr(abs_file.buffer) + repr(abs_file.buffer.raw)
        print('file-buffer-name-abs=' + abs_file.buffer.name)
        print('file-buffer-raw-name-abs=' + abs_file.buffer.raw.name)
        print('file-buffer-repr-abs=' + str("name='/tmp/a.txt'" in repr(abs_file.buffer)))
        print('file-buffer-abs-leaks=' + str(any(fragment in abs_buffer_text for fragment in ['vfs-materialized', 'materialized-', '\(rootURL.path)'])))
        abs_file.close()
        path_file = Path('/tmp/a.txt').open(encoding='utf-8')
        print('path-open-name=' + path_file.name)
        path_file.close()
        binary_file = open('/tmp/a.txt', 'rb')
        binary_text = binary_file.raw.name + repr(binary_file.raw)
        print('file-raw-name-bin=' + binary_file.raw.name)
        print('file-raw-bin-leaks=' + str(any(fragment in binary_text for fragment in ['vfs-materialized', 'materialized-', '\(rootURL.path)'])))
        binary_file.close()
        os.chdir('/tmp')
        print('cwd2=' + os.getcwd())
        rel_file = open('a.txt', encoding='utf-8')
        rel_repr = repr(rel_file)
        print('file-name-rel=' + rel_file.name)
        print('file-repr-rel=' + str("name='a.txt'" in rel_repr))
        print('file-repr-rel-leaks=' + str(any(fragment in rel_repr for fragment in ['vfs-materialized', 'materialized-', '\(rootURL.path)'])))
        print('file-buffer-name-rel=' + rel_file.buffer.name)
        print('file-buffer-raw-name-rel=' + rel_file.buffer.raw.name)
        rel_file.close()
        shutil.copyfile('a.txt', 'b.txt')
        print('copy=' + Path('/tmp/b.txt').read_text(encoding='utf-8').strip())
        same_abs = open('/tmp/a.txt', encoding='utf-8')
        same_rel = open('a.txt', encoding='utf-8')
        same_other = open('b.txt', encoding='utf-8')
        try:
            print('sameopenfile-same=' + str(os.path.sameopenfile(same_abs.fileno(), same_rel.fileno())))
            print('sameopenfile-diff=' + str(os.path.sameopenfile(same_abs.fileno(), same_other.fileno())))
        finally:
            same_abs.close()
            same_rel.close()
            same_other.close()
        print('samefile-rel-abs=' + str(os.path.samefile('a.txt', '/tmp/a.txt')))
        print('samefile-host=' + str(os.path.samefile('/tmp/a.txt', '\(rootURL.path)/tmp/a.txt')))
        print('samefile-diff=' + str(os.path.samefile('/tmp/a.txt', '/tmp/b.txt')))
        print('path-samefile=' + str(Path('/tmp/a.txt').samefile('a.txt')))
        print('path-samefile-diff=' + str(Path('/tmp/a.txt').samefile('/tmp/b.txt')))
        print('samestat-same=' + str(os.path.samestat(os.stat('/tmp/a.txt'), os.stat('a.txt'))))
        print('samestat-diff=' + str(os.path.samestat(os.stat('/tmp/a.txt'), os.stat('/tmp/b.txt'))))
        print('stat-inode-diff=' + str(os.stat('/tmp/a.txt').st_ino != os.stat('/tmp/b.txt').st_ino))
        print('direntry-inode-diff=' + str(abs_entry.inode() != next(entry for entry in os.scandir('/tmp') if entry.name == 'b.txt').inode()))
        fdopen_fd = os.open('/tmp/fdopen.txt', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        fdopen_file = os.fdopen(fdopen_fd, 'w', encoding='utf-8')
        fdopen_repr = repr(fdopen_file)
        print('fdopen-name-is-int=' + str(fdopen_file.name == fdopen_fd))
        print('fdopen-repr-leaks=' + str(any(fragment in fdopen_repr for fragment in ['vfs-materialized', 'materialized-', '\(rootURL.path)'])))
        fdopen_file.write('fdopen-data')
        fdopen_file.close()
        print('fdopen-read=' + Path('/tmp/fdopen.txt').read_text(encoding='utf-8'))
        openfd_fd = os.open('/tmp/openfd.txt', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        openfd_file = open(openfd_fd, 'w', encoding='utf-8')
        openfd_repr = repr(openfd_file)
        print('openfd-name-is-int=' + str(openfd_file.name == openfd_fd))
        print('openfd-repr-leaks=' + str(any(fragment in openfd_repr for fragment in ['vfs-materialized', 'materialized-', '\(rootURL.path)'])))
        openfd_file.write('openfd-data')
        openfd_file.close()
        print('openfd-read=' + Path('/tmp/openfd.txt').read_text(encoding='utf-8'))
        fstat_fd = os.open('/tmp/fdopen.txt', os.O_RDONLY)
        try:
            print('fstat-samestat=' + str(os.path.samestat(os.fstat(fstat_fd), os.stat('/tmp/fdopen.txt'))))
            print('fstat-diff=' + str(os.path.samestat(os.fstat(fstat_fd), os.stat('/tmp/b.txt'))))
            fd_reader = open(fstat_fd, 'r', encoding='utf-8')
            try:
                print('openfd-read-name-is-int=' + str(fd_reader.name == fstat_fd))
                print('openfd-read-via-fd=' + fd_reader.read())
            finally:
                fd_reader.close()
        finally:
            try:
                os.close(fstat_fd)
            except OSError:
                pass
        dup_fd = os.open('/tmp/dup.txt', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        dup_alias = os.dup(dup_fd)
        print('dup-sameopenfile=' + str(os.path.sameopenfile(dup_fd, dup_alias)))
        print('dup-fstat-samestat=' + str(os.path.samestat(os.fstat(dup_alias), os.stat('/tmp/dup.txt'))))
        os.write(dup_fd, b'left-')
        pending_dup_entry = next(entry for entry in os.scandir('/tmp') if entry.name == 'dup.txt')
        print('dup-pending-list=' + str('dup.txt' in os.listdir('/tmp')))
        print('dup-pending-scandir=' + pending_dup_entry.path + ':' + str(pending_dup_entry.is_file()) + ':' + str(pending_dup_entry.stat().st_size))
        os.close(dup_fd)
        print('dup-after-first-close=' + Path('/tmp/dup.txt').read_text(encoding='utf-8'))
        os.write(dup_alias, b'right')
        os.close(dup_alias)
        print('dup-read=' + Path('/tmp/dup.txt').read_text(encoding='utf-8'))
        rename_fd = os.open('/tmp/pending-rename-source.txt', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.write(rename_fd, b'renamed')
        os.rename('/tmp/pending-rename-source.txt', '/tmp/pending-rename-target.txt')
        print('pending-rename-old-exists=' + str(Path('/tmp/pending-rename-source.txt').exists()))
        print('pending-rename-list=' + str('pending-rename-target.txt' in os.listdir('/tmp')))
        print('pending-rename-read=' + Path('/tmp/pending-rename-target.txt').read_text(encoding='utf-8'))
        os.write(rename_fd, b'-tail')
        os.close(rename_fd)
        print('pending-rename-final=' + Path('/tmp/pending-rename-target.txt').read_text(encoding='utf-8'))
        chmod_fd = os.open('/tmp/pending-chmod.txt', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.write(chmod_fd, b'chmod-data')
        os.chmod('/tmp/pending-chmod.txt', 0o640)
        print('pending-chmod-mode-before=%03o' % stat.S_IMODE(os.stat('/tmp/pending-chmod.txt').st_mode))
        print('pending-access-rw=' + str(os.access('/tmp/pending-chmod.txt', os.R_OK | os.W_OK)))
        print('pending-access-x=' + str(os.access('/tmp/pending-chmod.txt', os.X_OK)))
        os.utime('/tmp/pending-chmod.txt', (1111111111, 1111111111))
        print('pending-utime-before=%d' % int(os.stat('/tmp/pending-chmod.txt').st_mtime))
        os.utime(chmod_fd, (333333333, 333333333))
        print('pending-fd-utime-before=%d' % int(os.stat('/tmp/pending-chmod.txt').st_mtime))
        os.close(chmod_fd)
        print('pending-chmod-mode-after=%03o' % stat.S_IMODE(os.stat('/tmp/pending-chmod.txt').st_mode))
        print('pending-chmod-read=' + Path('/tmp/pending-chmod.txt').read_text(encoding='utf-8'))
        Path('/tmp/truncate-existing.txt').write_text('abcdef', encoding='utf-8')
        os.truncate('/tmp/truncate-existing.txt', 4)
        print('truncate-existing=' + Path('/tmp/truncate-existing.txt').read_text(encoding='utf-8'))
        truncate_fd = os.open('/tmp/pending-truncate.txt', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.write(truncate_fd, b'abcdef')
        os.truncate('/tmp/pending-truncate.txt', 5)
        print('pending-truncate-path=' + Path('/tmp/pending-truncate.txt').read_text(encoding='utf-8'))
        os.truncate(truncate_fd, 4)
        print('pending-truncate-fd=' + Path('/tmp/pending-truncate.txt').read_text(encoding='utf-8'))
        os.ftruncate(truncate_fd, 3)
        print('pending-ftruncate=' + Path('/tmp/pending-truncate.txt').read_text(encoding='utf-8'))
        os.close(truncate_fd)
        print('pending-truncate-final=' + Path('/tmp/pending-truncate.txt').read_text(encoding='utf-8'))
        dup_read_fd = os.open('/tmp/dup.txt', os.O_RDONLY)
        dup_read_alias = os.dup(dup_read_fd)
        try:
            print('dup-read-fstat=' + str(os.path.samestat(os.fstat(dup_read_alias), os.stat('/tmp/dup.txt'))))
            os.close(dup_read_fd)
            print('dup-read-bytes=' + os.read(dup_read_alias, 5).decode('utf-8'))
        finally:
            try:
                os.close(dup_read_alias)
            except OSError:
                pass
        dup2_source_fd = os.open('/tmp/dup2-source.txt', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        dup2_target_fd = os.open('/tmp/dup2-target.txt', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.write(dup2_target_fd, b'old')
        os.write(dup2_source_fd, b'new')
        dup2_result = os.dup2(dup2_source_fd, dup2_target_fd)
        print('dup2-return-target=' + str(dup2_result == dup2_target_fd))
        print('dup2-fstat-samestat=' + str(os.path.samestat(os.fstat(dup2_target_fd), os.stat('/tmp/dup2-source.txt'))))
        os.close(dup2_source_fd)
        os.write(dup2_target_fd, b'-alias')
        os.close(dup2_target_fd)
        print('dup2-source-read=' + Path('/tmp/dup2-source.txt').read_text(encoding='utf-8'))
        print('dup2-target-read=' + Path('/tmp/dup2-target.txt').read_text(encoding='utf-8'))
        print('abspath-rel=' + os.path.abspath('a.txt'))
        print('realpath-rel=' + os.path.realpath('a.txt'))
        print('realpath-virtual=' + os.path.realpath('/tmp/a.txt'))
        print('realpath-host=' + os.path.realpath('\(rootURL.path)/tmp/a.txt'))
        print('relpath=' + os.path.relpath('/tmp/a.txt', '/tmp'))
        print('resolve-rel=' + str(Path('a.txt').resolve()))
        print('resolve-host=' + str(Path('\(rootURL.path)/tmp/a.txt').resolve()))
        try:
            os.path.realpath('/tmp/missing.txt', strict=True)
        except FileNotFoundError as error:
            print('realpath-strict-missing=' + (error.filename or ''))
        try:
            Path('/tmp/missing.txt').resolve(strict=True)
        except FileNotFoundError as error:
            print('resolve-strict-missing=' + (error.filename or ''))
        print('host-path=' + str(Path('\(rootURL.path)/tmp/a.txt')))
        sys.stdout.flush()
        sys.stdout.buffer.write(b'buffer-out=\(rootURL.path)/tmp/a.txt\\n')
        sys.stdout.buffer.flush()
        sys.stderr.buffer.write(b'buffer-err=\(rootURL.path)/tmp/a.txt\\n')
        sys.stderr.buffer.flush()
        PY
        """)

        XCTAssertEqual(result.stderr, "buffer-err=/tmp/a.txt\n")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, """
        cwd=/
        tmpdir=/tmp
        internal-env=
        read=hello
        list=a.txt
        exists=True
        scandir-abs-path=/tmp/a.txt
        scandir-abs-fspath=/tmp/a.txt
        scandir-abs-repr=<DirEntry 'a.txt'>
        scandir-abs-leaks=False
        scandir-rel-path=tmp/a.txt
        scandir-dot-path=./tmp
        file-name-abs=/tmp/a.txt
        file-repr-abs=True
        file-repr-abs-leaks=False
        file-buffer-name-abs=/tmp/a.txt
        file-buffer-raw-name-abs=/tmp/a.txt
        file-buffer-repr-abs=True
        file-buffer-abs-leaks=False
        path-open-name=/tmp/a.txt
        file-raw-name-bin=/tmp/a.txt
        file-raw-bin-leaks=False
        cwd2=/tmp
        file-name-rel=a.txt
        file-repr-rel=True
        file-repr-rel-leaks=False
        file-buffer-name-rel=a.txt
        file-buffer-raw-name-rel=a.txt
        copy=hello
        sameopenfile-same=True
        sameopenfile-diff=False
        samefile-rel-abs=True
        samefile-host=True
        samefile-diff=False
        path-samefile=True
        path-samefile-diff=False
        samestat-same=True
        samestat-diff=False
        stat-inode-diff=True
        direntry-inode-diff=True
        fdopen-name-is-int=True
        fdopen-repr-leaks=False
        fdopen-read=fdopen-data
        openfd-name-is-int=True
        openfd-repr-leaks=False
        openfd-read=openfd-data
        fstat-samestat=True
        fstat-diff=False
        openfd-read-name-is-int=True
        openfd-read-via-fd=fdopen-data
        dup-sameopenfile=True
        dup-fstat-samestat=True
        dup-pending-list=True
        dup-pending-scandir=/tmp/dup.txt:True:5
        dup-after-first-close=left-
        dup-read=left-right
        pending-rename-old-exists=False
        pending-rename-list=True
        pending-rename-read=renamed
        pending-rename-final=renamed-tail
        pending-chmod-mode-before=640
        pending-access-rw=True
        pending-access-x=False
        pending-utime-before=1111111111
        pending-fd-utime-before=333333333
        pending-chmod-mode-after=640
        pending-chmod-read=chmod-data
        truncate-existing=abcd
        pending-truncate-path=abcde
        pending-truncate-fd=abcd
        pending-ftruncate=abc
        pending-truncate-final=abc
        dup-read-fstat=True
        dup-read-bytes=left-
        dup2-return-target=True
        dup2-fstat-samestat=True
        dup2-source-read=new-alias
        dup2-target-read=old
        abspath-rel=/tmp/a.txt
        realpath-rel=/tmp/a.txt
        realpath-virtual=/tmp/a.txt
        realpath-host=/tmp/a.txt
        relpath=a.txt
        resolve-rel=/tmp/a.txt
        resolve-host=/tmp/a.txt
        realpath-strict-missing=/tmp/missing.txt
        resolve-strict-missing=/tmp/missing.txt
        host-path=/tmp/a.txt
        buffer-out=/tmp/a.txt

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("msp-python-launcher.py"))
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("tmp/a.txt"), encoding: .utf8),
            "hello\n"
        )
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("tmp/b.txt"), encoding: .utf8),
            "hello\n"
        )
        XCTAssertEqual(
            try relativeWorkspacePaths(under: rootURL),
            [
                "tmp",
                "tmp/a.txt",
                "tmp/b.txt",
                "tmp/dup.txt",
                "tmp/dup2-source.txt",
                "tmp/dup2-target.txt",
                "tmp/fdopen.txt",
                "tmp/openfd.txt",
                "tmp/pending-chmod.txt",
                "tmp/pending-rename-target.txt",
                "tmp/pending-truncate.txt",
                "tmp/truncate-existing.txt"
            ]
        )
    }
}
#endif
