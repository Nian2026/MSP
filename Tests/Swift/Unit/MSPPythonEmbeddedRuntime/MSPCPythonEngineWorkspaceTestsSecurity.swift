import Foundation
import XCTest
import ModelShellProxy
import MSPApple
import MSPPythonEmbeddedRuntime

final class MSPCPythonEngineWorkspaceTestsSecurity: MSPPythonEmbeddedRuntimeTestCase {
    func testCPythonEngineVFSGuardsImportsLinksPathStringsAndRealPathEscapesWhenLibraryIsAvailable() async throws {
        guard let library = Self.localCPythonLibrary() else {
            throw XCTSkip("Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython VFS guard test.")
        }
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let hostSecretURL = rootURL.appendingPathComponent("host-secret.txt")
        try Data("secret\n".utf8).write(to: hostSecretURL)
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
        import importlib
        import os
        import stat
        import sys

        for name in ["pip", "ensurepip", "venv", "multiprocessing"]:
            for label, loader in [("import", __import__), ("import_module", importlib.import_module)]:
                try:
                    loader(name)
                except PermissionError:
                    print(label + ":" + name + "=blocked")
                else:
                    print(label + ":" + name + "=allowed")

        Path('/tmp').mkdir(exist_ok=True)
        Path('/tmp/source.txt').write_text('ok', encoding='utf-8')
        print('str-path=' + str(Path('\(rootURL.path)/tmp/source.txt')))
        abs_entry = next(entry for entry in os.scandir('/tmp') if entry.name == 'source.txt')
        abs_entry_text = abs_entry.path + repr(abs_entry) + os.fspath(abs_entry)
        print('scandir-abs-path=' + abs_entry.path)
        print('scandir-abs-fspath=' + os.fspath(abs_entry))
        print('scandir-abs-repr=' + repr(abs_entry))
        print('scandir-abs-leaks=' + str(any(fragment in abs_entry_text for fragment in ['vfs-materialized', 'materialized-', '\(rootURL.path)'])))
        rel_entry = next(entry for entry in os.scandir('tmp') if entry.name == 'source.txt')
        print('scandir-rel-path=' + rel_entry.path)
        dot_entry = next(entry for entry in os.scandir('.') if entry.name == 'tmp')
        print('scandir-dot-path=' + dot_entry.path)
        abs_file = open('/tmp/source.txt', encoding='utf-8')
        abs_repr = repr(abs_file)
        print('file-name-abs=' + abs_file.name)
        print('file-repr-abs=' + str("name='/tmp/source.txt'" in abs_repr))
        print('file-repr-abs-leaks=' + str(any(fragment in abs_repr for fragment in ['vfs-materialized', 'materialized-', '\(rootURL.path)'])))
        abs_buffer_text = abs_file.buffer.name + abs_file.buffer.raw.name + repr(abs_file.buffer) + repr(abs_file.buffer.raw)
        print('file-buffer-name-abs=' + abs_file.buffer.name)
        print('file-buffer-raw-name-abs=' + abs_file.buffer.raw.name)
        print('file-buffer-repr-abs=' + str("name='/tmp/source.txt'" in repr(abs_file.buffer)))
        print('file-buffer-abs-leaks=' + str(any(fragment in abs_buffer_text for fragment in ['vfs-materialized', 'materialized-', '\(rootURL.path)'])))
        abs_file.close()
        path_file = Path('/tmp/source.txt').open(encoding='utf-8')
        print('path-open-name=' + path_file.name)
        path_file.close()
        binary_file = open('/tmp/source.txt', 'rb')
        binary_text = binary_file.raw.name + repr(binary_file.raw)
        print('file-raw-name-bin=' + binary_file.raw.name)
        print('file-raw-bin-leaks=' + str(any(fragment in binary_text for fragment in ['vfs-materialized', 'materialized-', '\(rootURL.path)'])))
        binary_file.close()
        os.chdir('/tmp')
        rel_file = open('source.txt', encoding='utf-8')
        rel_repr = repr(rel_file)
        print('file-name-rel=' + rel_file.name)
        print('file-repr-rel=' + str("name='source.txt'" in rel_repr))
        print('file-repr-rel-leaks=' + str(any(fragment in rel_repr for fragment in ['vfs-materialized', 'materialized-', '\(rootURL.path)'])))
        print('file-buffer-name-rel=' + rel_file.buffer.name)
        print('file-buffer-raw-name-rel=' + rel_file.buffer.raw.name)
        rel_file.close()
        Path('/tmp/other.txt').write_text('other', encoding='utf-8')
        same_abs = open('/tmp/source.txt', encoding='utf-8')
        same_rel = open('source.txt', encoding='utf-8')
        same_other = open('other.txt', encoding='utf-8')
        try:
            print('sameopenfile-same=' + str(os.path.sameopenfile(same_abs.fileno(), same_rel.fileno())))
            print('sameopenfile-diff=' + str(os.path.sameopenfile(same_abs.fileno(), same_other.fileno())))
        finally:
            same_abs.close()
            same_rel.close()
            same_other.close()
        print('samefile-rel-abs=' + str(os.path.samefile('source.txt', '/tmp/source.txt')))
        print('samefile-host=' + str(os.path.samefile('/tmp/source.txt', '\(rootURL.path)/tmp/source.txt')))
        print('samefile-diff=' + str(os.path.samefile('/tmp/source.txt', '/tmp/other.txt')))
        print('path-samefile=' + str(Path('/tmp/source.txt').samefile('source.txt')))
        print('path-samefile-diff=' + str(Path('/tmp/source.txt').samefile('/tmp/other.txt')))
        print('samestat-same=' + str(os.path.samestat(os.stat('/tmp/source.txt'), os.stat('source.txt'))))
        print('samestat-diff=' + str(os.path.samestat(os.stat('/tmp/source.txt'), os.stat('/tmp/other.txt'))))
        print('stat-inode-diff=' + str(os.stat('/tmp/source.txt').st_ino != os.stat('/tmp/other.txt').st_ino))
        print('direntry-inode-diff=' + str(abs_entry.inode() != next(entry for entry in os.scandir('/tmp') if entry.name == 'other.txt').inode()))
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
            print('fstat-diff=' + str(os.path.samestat(os.fstat(fstat_fd), os.stat('/tmp/other.txt'))))
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
        os.chdir('/')
        print('abspath-rel=' + os.path.abspath('tmp/source.txt'))
        print('realpath-virtual=' + os.path.realpath('/tmp/source.txt'))
        print('realpath-host=' + os.path.realpath('\(rootURL.path)/tmp/source.txt'))
        print('relpath=' + os.path.relpath('/tmp/source.txt', '/tmp'))
        print('resolve-virtual=' + str(Path('/tmp/source.txt').resolve()))
        print('resolve-host=' + str(Path('\(rootURL.path)/tmp/source.txt').resolve()))
        try:
            os.path.realpath('/tmp/missing.txt', strict=True)
        except FileNotFoundError as error:
            print('realpath-strict-missing=' + (error.filename or ''))
        try:
            Path('/tmp/missing.txt').resolve(strict=True)
        except FileNotFoundError as error:
            print('resolve-strict-missing=' + (error.filename or ''))

        for label, call in [
            ("symlink", lambda: os.symlink('/tmp/source.txt', '/tmp/link.txt')),
            ("link", lambda: os.link('/tmp/source.txt', '/tmp/hard.txt')),
        ]:
            try:
                call()
            except PermissionError:
                print(label + '=blocked')
            else:
                print(label + '=allowed')

        original_open = getattr(sys, '__msp_python_vfs_originals__')['builtins_open']
        try:
            original_open('\(hostSecretURL.path)', encoding='utf-8').read()
        except PermissionError:
            print('real-open=blocked')
        else:
            print('real-open=allowed')
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        import:pip=blocked
        import_module:pip=blocked
        import:ensurepip=blocked
        import_module:ensurepip=blocked
        import:venv=blocked
        import_module:venv=blocked
        import:multiprocessing=blocked
        import_module:multiprocessing=blocked
        str-path=/tmp/source.txt
        scandir-abs-path=/tmp/source.txt
        scandir-abs-fspath=/tmp/source.txt
        scandir-abs-repr=<DirEntry 'source.txt'>
        scandir-abs-leaks=False
        scandir-rel-path=tmp/source.txt
        scandir-dot-path=./tmp
        file-name-abs=/tmp/source.txt
        file-repr-abs=True
        file-repr-abs-leaks=False
        file-buffer-name-abs=/tmp/source.txt
        file-buffer-raw-name-abs=/tmp/source.txt
        file-buffer-repr-abs=True
        file-buffer-abs-leaks=False
        path-open-name=/tmp/source.txt
        file-raw-name-bin=/tmp/source.txt
        file-raw-bin-leaks=False
        file-name-rel=source.txt
        file-repr-rel=True
        file-repr-rel-leaks=False
        file-buffer-name-rel=source.txt
        file-buffer-raw-name-rel=source.txt
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
        abspath-rel=/tmp/source.txt
        realpath-virtual=/tmp/source.txt
        realpath-host=/tmp/source.txt
        relpath=source.txt
        resolve-virtual=/tmp/source.txt
        resolve-host=/tmp/source.txt
        realpath-strict-missing=/tmp/missing.txt
        resolve-strict-missing=/tmp/missing.txt
        symlink=blocked
        link=blocked
        real-open=blocked

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("subprocess-broker"))
    }
}
