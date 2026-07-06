import Foundation
import XCTest
import ModelShellProxy
import MSPApple
import MSPPythonEmbeddedRuntime

final class MSPCPythonEngineWorkspaceTestsBytesAndMetadata: MSPPythonEmbeddedRuntimeTestCase {
    func testCPythonEngineBytesPathsUseVirtualWorkspaceWhenLibraryIsAvailable() async throws {
        let fixture = try embeddedCPythonShell(
            skipMessage: "Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython VFS bytes path test."
        )
        defer { fixture.cleanup() }

        let result = await fixture.shell.run("""
        python3 - <<'PY'
        from pathlib import Path
        import os

        Path('/tmp/sub').mkdir(parents=True, exist_ok=True)
        Path('/tmp/a.txt').write_text('alpha', encoding='utf-8')
        Path('/tmp/sub/b.txt').write_text('beta', encoding='utf-8')
        print('exists-bytes=' + str(os.path.exists(b'/tmp/a.txt')))
        print('isfile-bytes=' + str(os.path.isfile(b'/tmp/a.txt')))
        print('isdir-bytes=' + str(os.path.isdir(b'/tmp')))
        print('abspath-bytes=' + repr(os.path.abspath(b'tmp/a.txt')))
        print('realpath-bytes=' + repr(os.path.realpath(b'/tmp/a.txt')))
        print('relpath-bytes=' + repr(os.path.relpath(b'/tmp/a.txt', b'/tmp')))
        print('samefile-bytes-str=' + str(os.path.samefile(b'/tmp/a.txt', '/tmp/a.txt')))
        with open(b'/tmp/a.txt', 'r', encoding='utf-8') as file:
            print('open-name=' + repr(file.name))
            print('open-read=' + file.read())
        with open(b'/tmp/new.txt', 'w', encoding='utf-8') as file:
            print('write-name=' + repr(file.name))
            file.write('new')
        print('new-read=' + Path('/tmp/new.txt').read_text(encoding='utf-8'))
        print('listdir-bytes=' + repr(sorted(os.listdir(b'/tmp'))))
        entry = next(entry for entry in os.scandir(b'/tmp') if entry.name == b'a.txt')
        print('scandir-name=' + repr(entry.name))
        print('scandir-path=' + repr(entry.path))
        print('scandir-fspath=' + repr(os.fspath(entry)))
        print('scandir-is-file=' + str(entry.is_file()))
        try:
            os.path.relpath(b'/tmp/a.txt', '/tmp')
        except TypeError as error:
            print('relpath-mix=' + type(error).__name__)
        else:
            print('relpath-mix=allowed')
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        exists-bytes=True
        isfile-bytes=True
        isdir-bytes=True
        abspath-bytes=b'/tmp/a.txt'
        realpath-bytes=b'/tmp/a.txt'
        relpath-bytes=b'a.txt'
        samefile-bytes-str=True
        open-name=b'/tmp/a.txt'
        open-read=alpha
        write-name=b'/tmp/new.txt'
        new-read=new
        listdir-bytes=[b'a.txt', b'new.txt', b'sub']
        scandir-name=b'a.txt'
        scandir-path=b'/tmp/a.txt'
        scandir-fspath=b'/tmp/a.txt'
        scandir-is-file=True
        relpath-mix=TypeError

        """)
        assertNoEmbeddedCPythonHostLeak(result.stdout + result.stderr, rootURL: fixture.rootURL)
    }

    func testCPythonEngineAnonymousOpenIterationKeepsVFSFileAliveWhenLibraryIsAvailable() async throws {
        let fixture = try embeddedCPythonShell(
            skipMessage: "Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython anonymous open iteration test."
        )
        defer { fixture.cleanup() }

        let result = await fixture.shell.run("""
        python3 -S - <<'PY'
        from pathlib import Path

        Path('/tmp').mkdir(exist_ok=True)
        Path('/tmp/pool.txt').write_text('alpha\\nbeta\\n', encoding='utf-8')
        paths = [line.rstrip('\\n') for line in open('/tmp/pool.txt', encoding='utf-8')]
        print('paths=' + repr(paths))
        first = next(iter(open('/tmp/pool.txt', encoding='utf-8'))).strip()
        print('first=' + first)
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        paths=['alpha', 'beta']
        first=alpha

        """)
        assertNoEmbeddedCPythonHostLeak(result.stdout + result.stderr, rootURL: fixture.rootURL)
    }

    func testCPythonEngineBytesPathErrorsPreserveBytesFilenamesWhenLibraryIsAvailable() async throws {
        let fixture = try embeddedCPythonShell(
            skipMessage: "Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython VFS bytes path error test."
        )
        defer { fixture.cleanup() }

        let result = await fixture.shell.run("""
        python3 - <<'PY'
        import os

        def describe(label, action):
            try:
                action()
            except Exception as error:
                filename = getattr(error, 'filename', None)
                filename2 = getattr(error, 'filename2', None)
                print(label + '-type=' + type(error).__name__)
                print(label + '-filename=' + repr(filename) + '|type=' + type(filename).__name__)
                print(label + '-filename2=' + repr(filename2) + '|type=' + type(filename2).__name__)
                print(label + '-text=' + str(error))
            else:
                print(label + '=allowed')

        describe('open-missing-bytes', lambda: open(b'tmp/missing.txt', 'r'))
        describe('stat-missing-bytes', lambda: os.stat(b'tmp/missing.txt'))
        describe('listdir-missing-bytes', lambda: os.listdir(b'tmp/missing'))
        describe('rename-missing-bytes', lambda: os.rename(b'tmp/missing.txt', b'tmp/target.txt'))
        describe('rename-mix-src-bytes', lambda: os.rename(b'tmp/missing.txt', 'tmp/target.txt'))
        describe('remove-missing-bytes', lambda: os.remove(b'tmp/missing.txt'))
        describe('osopen-missing-bytes', lambda: os.open(b'tmp/missing.txt', os.O_RDONLY))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        open-missing-bytes-type=FileNotFoundError
        open-missing-bytes-filename=b'tmp/missing.txt'|type=bytes
        open-missing-bytes-filename2=None|type=NoneType
        open-missing-bytes-text=[Errno 2] No such file or directory: b'tmp/missing.txt'
        stat-missing-bytes-type=FileNotFoundError
        stat-missing-bytes-filename=b'tmp/missing.txt'|type=bytes
        stat-missing-bytes-filename2=None|type=NoneType
        stat-missing-bytes-text=[Errno 2] No such file or directory: b'tmp/missing.txt'
        listdir-missing-bytes-type=FileNotFoundError
        listdir-missing-bytes-filename=b'tmp/missing'|type=bytes
        listdir-missing-bytes-filename2=None|type=NoneType
        listdir-missing-bytes-text=[Errno 2] No such file or directory: b'tmp/missing'
        rename-missing-bytes-type=FileNotFoundError
        rename-missing-bytes-filename=b'tmp/missing.txt'|type=bytes
        rename-missing-bytes-filename2=b'tmp/target.txt'|type=bytes
        rename-missing-bytes-text=[Errno 2] No such file or directory: b'tmp/missing.txt' -> b'tmp/target.txt'
        rename-mix-src-bytes-type=FileNotFoundError
        rename-mix-src-bytes-filename=b'tmp/missing.txt'|type=bytes
        rename-mix-src-bytes-filename2='tmp/target.txt'|type=str
        rename-mix-src-bytes-text=[Errno 2] No such file or directory: b'tmp/missing.txt' -> 'tmp/target.txt'
        remove-missing-bytes-type=FileNotFoundError
        remove-missing-bytes-filename=b'tmp/missing.txt'|type=bytes
        remove-missing-bytes-filename2=None|type=NoneType
        remove-missing-bytes-text=[Errno 2] No such file or directory: b'tmp/missing.txt'
        osopen-missing-bytes-type=FileNotFoundError
        osopen-missing-bytes-filename=b'tmp/missing.txt'|type=bytes
        osopen-missing-bytes-filename2=None|type=NoneType
        osopen-missing-bytes-text=[Errno 2] No such file or directory: b'tmp/missing.txt'

        """)
        assertNoEmbeddedCPythonHostLeak(result.stdout + result.stderr, rootURL: fixture.rootURL)
    }
    func testCPythonEngineStatAcceptsVirtualFileDescriptorWhenLibraryIsAvailable() async throws {
        let fixture = try embeddedCPythonShell(
            skipMessage: "Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython VFS fd stat test."
        )
        defer { fixture.cleanup() }

        let result = await fixture.shell.run("""
        python3 - <<'PY'
        from pathlib import Path
        import os
        import shutil
        import stat

        Path('/tmp').mkdir(exist_ok=True)
        Path('/tmp/stat-dir').mkdir(exist_ok=True)
        Path('/tmp/stat-fd.txt').write_text('stat-data', encoding='utf-8')
        Path('/tmp/stat-other.txt').write_text('stat-data', encoding='utf-8')
        Path('/tmp/stat-dir/file.txt').write_text('disk-data', encoding='utf-8')
        for label, target in [
            ('root', '/'),
            ('tmp', '/tmp'),
            ('dir', Path('/tmp/stat-dir')),
            ('file', '/tmp/stat-dir/file.txt'),
        ]:
            statvfs = os.statvfs(target)
            usage = shutil.disk_usage(target)
            print(label + '-statvfs=' + repr((type(statvfs).__name__, statvfs.f_bsize > 0, statvfs.f_blocks >= 0)))
            print(label + '-disk=' + repr((type(usage).__name__, usage.total >= 0, usage.used >= 0, usage.free >= 0)))
        for label, target in [
            ('statvfs-missing-str', '/tmp/stat-missing'),
            ('statvfs-missing-bytes', b'/tmp/stat-missing'),
        ]:
            try:
                os.statvfs(target)
            except OSError as error:
                print(label + '=' + type(error).__name__ + ':' + repr(getattr(error, 'filename', None)) + ':' + str(error))
            else:
                print(label + '=allowed')
        if hasattr(os, 'pathconf') and hasattr(os, 'fpathconf'):
            for label, target in [
                ('root', '/'),
                ('tmp', '/tmp'),
                ('dir', Path('/tmp/stat-dir')),
                ('file', '/tmp/stat-dir/file.txt'),
            ]:
                value = os.pathconf(target, 'PC_NAME_MAX')
                value_by_number = os.pathconf(target, os.pathconf_names['PC_NAME_MAX'])
                print(label + '-pathconf=' + repr((type(value).__name__, value > 0, value == value_by_number)))
            for label, target in [
                ('pathconf-missing-str', '/tmp/pathconf-missing'),
                ('pathconf-missing-bytes', b'/tmp/pathconf-missing'),
            ]:
                try:
                    os.pathconf(target, 'PC_NAME_MAX')
                except OSError as error:
                    print(label + '=' + type(error).__name__ + ':' + repr(getattr(error, 'filename', None)) + ':' + str(error))
                else:
                    print(label + '=allowed')
            for label, target, name in [
                ('pathconf-invalid-string-existing', '/tmp/stat-dir', 'NO_SUCH_CONF'),
                ('pathconf-invalid-string-missing', '/tmp/pathconf-missing', 'NO_SUCH_CONF'),
                ('pathconf-invalid-type-existing', '/tmp/stat-dir', b'PC_NAME_MAX'),
                ('pathconf-invalid-type-missing', '/tmp/pathconf-missing', b'PC_NAME_MAX'),
            ]:
                try:
                    os.pathconf(target, name)
                except Exception as error:
                    print(label + '=' + type(error).__name__ + ':' + repr(getattr(error, 'filename', None)) + ':' + str(error))
                else:
                    print(label + '=allowed')
        fd = os.open('/tmp/stat-fd.txt', os.O_RDONLY)
        try:
            stat_fd = os.stat(fd)
            fstat_fd = os.fstat(fd)
            stat_path = os.stat('/tmp/stat-fd.txt')
            statvfs_fd = os.statvfs(fd)
            fstatvfs_fd = os.fstatvfs(fd)
            disk_fd = shutil.disk_usage(fd)
            if hasattr(os, 'pathconf') and hasattr(os, 'fpathconf'):
                pathconf_fd = os.pathconf(fd, 'PC_NAME_MAX')
                fpathconf_fd = os.fpathconf(fd, 'PC_NAME_MAX')
                pathconf_fd_by_number = os.pathconf(fd, os.pathconf_names['PC_NAME_MAX'])
                print('pathconf-fd=' + repr((type(pathconf_fd).__name__, pathconf_fd > 0, pathconf_fd == pathconf_fd_by_number)))
                print('fpathconf-fd=' + repr((type(fpathconf_fd).__name__, fpathconf_fd > 0)))
                for label, action in [
                    ('pathconf-bad-fd', lambda: os.pathconf(999999, 'PC_NAME_MAX')),
                    ('fpathconf-bad-fd', lambda: os.fpathconf(999999, 'PC_NAME_MAX')),
                ]:
                    try:
                        action()
                    except OSError as error:
                        print(label + '=' + type(error).__name__ + ':' + repr(getattr(error, 'filename', None)) + ':' + str(error))
                    else:
                        print(label + '=allowed')
            print('statfd-fstat=' + str(os.path.samestat(stat_fd, fstat_fd)))
            print('statfd-path=' + str(os.path.samestat(stat_fd, stat_path)))
            print('statfd-size=' + str(stat_fd.st_size))
            print('fstat-size=' + str(fstat_fd.st_size))
            print('statvfs-fd=' + repr((type(statvfs_fd).__name__, statvfs_fd.f_bsize > 0)))
            print('fstatvfs-fd=' + repr((type(fstatvfs_fd).__name__, fstatvfs_fd.f_bsize > 0)))
            print('disk-fd=' + repr((type(disk_fd).__name__, disk_fd.total >= 0, disk_fd.free >= 0)))
            print('exists-fd=' + str(os.path.exists(fd)))
            print('isfile-fd=' + str(os.path.isfile(fd)))
            print('isdir-fd=' + str(os.path.isdir(fd)))
            print('getsize-fd=' + str(os.path.getsize(fd)))
            print('getmtime-fd-type=' + type(os.path.getmtime(fd)).__name__)
            print('samefile-fd-path=' + str(os.path.samefile(fd, '/tmp/stat-fd.txt')))
            print('samefile-path-fd=' + str(os.path.samefile('/tmp/stat-fd.txt', fd)))
            print('samefile-fd-other=' + str(os.path.samefile(fd, '/tmp/stat-other.txt')))
            print('samefile-fd-fd=' + str(os.path.samefile(fd, fd)))
            try:
                os.access(fd, os.R_OK)
            except TypeError as error:
                print('accessfd-type=' + type(error).__name__)
            else:
                print('accessfd-type=allowed')
            try:
                os.lstat(fd)
            except TypeError as error:
                print('lstatfd-type=' + type(error).__name__)
            else:
                print('lstatfd-type=allowed')
        finally:
            os.close(fd)
        dir_fd = os.open('/tmp', os.O_RDONLY | getattr(os, 'O_DIRECTORY', 0))
        try:
            print('dirfd-stat-isdir=' + str(stat.S_ISDIR(os.stat(dir_fd).st_mode)))
            statvfs_dirfd = os.statvfs(dir_fd)
            fstatvfs_dirfd = os.fstatvfs(dir_fd)
            disk_dirfd = shutil.disk_usage(dir_fd)
            if hasattr(os, 'pathconf') and hasattr(os, 'fpathconf'):
                pathconf_dirfd = os.pathconf(dir_fd, 'PC_NAME_MAX')
                fpathconf_dirfd = os.fpathconf(dir_fd, 'PC_NAME_MAX')
                print('pathconf-dirfd=' + repr((type(pathconf_dirfd).__name__, pathconf_dirfd > 0)))
                print('fpathconf-dirfd=' + repr((type(fpathconf_dirfd).__name__, fpathconf_dirfd > 0)))
            print('statvfs-dirfd=' + repr((type(statvfs_dirfd).__name__, statvfs_dirfd.f_bsize > 0)))
            print('fstatvfs-dirfd=' + repr((type(fstatvfs_dirfd).__name__, fstatvfs_dirfd.f_bsize > 0)))
            print('disk-dirfd=' + repr((type(disk_dirfd).__name__, disk_dirfd.total >= 0, disk_dirfd.free >= 0)))
            print('dirfd-exists=' + str(os.path.exists(dir_fd)))
            print('dirfd-isdir=' + str(os.path.isdir(dir_fd)))
            print('dirfd-isfile=' + str(os.path.isfile(dir_fd)))
            print('samefile-dirfd-dir=' + str(os.path.samefile(dir_fd, '/tmp')))
            try:
                os.lstat(dir_fd)
            except TypeError as error:
                print('dirfd-lstat-type=' + type(error).__name__)
            else:
                print('dirfd-lstat-type=allowed')
        finally:
            os.close(dir_fd)
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        root-statvfs=('statvfs_result', True, True)
        root-disk=('usage', True, True, True)
        tmp-statvfs=('statvfs_result', True, True)
        tmp-disk=('usage', True, True, True)
        dir-statvfs=('statvfs_result', True, True)
        dir-disk=('usage', True, True, True)
        file-statvfs=('statvfs_result', True, True)
        file-disk=('usage', True, True, True)
        statvfs-missing-str=FileNotFoundError:'/tmp/stat-missing':[Errno 2] No such file or directory: '/tmp/stat-missing'
        statvfs-missing-bytes=FileNotFoundError:b'/tmp/stat-missing':[Errno 2] No such file or directory: b'/tmp/stat-missing'
        root-pathconf=('int', True, True)
        tmp-pathconf=('int', True, True)
        dir-pathconf=('int', True, True)
        file-pathconf=('int', True, True)
        pathconf-missing-str=FileNotFoundError:'/tmp/pathconf-missing':[Errno 2] No such file or directory: '/tmp/pathconf-missing'
        pathconf-missing-bytes=FileNotFoundError:b'/tmp/pathconf-missing':[Errno 2] No such file or directory: b'/tmp/pathconf-missing'
        pathconf-invalid-string-existing=ValueError:None:unrecognized configuration name
        pathconf-invalid-string-missing=ValueError:None:unrecognized configuration name
        pathconf-invalid-type-existing=TypeError:None:configuration names must be strings or integers
        pathconf-invalid-type-missing=TypeError:None:configuration names must be strings or integers
        pathconf-fd=('int', True, True)
        fpathconf-fd=('int', True)
        pathconf-bad-fd=OSError:999999:[Errno 9] Bad file descriptor: 999999
        fpathconf-bad-fd=OSError:None:[Errno 9] Bad file descriptor
        statfd-fstat=True
        statfd-path=True
        statfd-size=9
        fstat-size=9
        statvfs-fd=('statvfs_result', True)
        fstatvfs-fd=('statvfs_result', True)
        disk-fd=('usage', True, True)
        exists-fd=True
        isfile-fd=True
        isdir-fd=False
        getsize-fd=9
        getmtime-fd-type=float
        samefile-fd-path=True
        samefile-path-fd=True
        samefile-fd-other=False
        samefile-fd-fd=True
        accessfd-type=TypeError
        lstatfd-type=TypeError
        dirfd-stat-isdir=True
        pathconf-dirfd=('int', True)
        fpathconf-dirfd=('int', True)
        statvfs-dirfd=('statvfs_result', True)
        fstatvfs-dirfd=('statvfs_result', True)
        disk-dirfd=('usage', True, True)
        dirfd-exists=True
        dirfd-isdir=True
        dirfd-isfile=False
        samefile-dirfd-dir=True
        dirfd-lstat-type=TypeError

        """)
        assertNoEmbeddedCPythonHostLeak(result.stdout + result.stderr, rootURL: fixture.rootURL)
    }
    func testCPythonEngineDefaultsVirtualTextFilesToUTF8WhenLibraryIsAvailable() async throws {
        guard let library = Self.localCPythonLibrary() else {
            throw XCTSkip("Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython UTF-8 default test.")
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
        LC_ALL=C LANG=C PYTHONUTF8=0 PYTHONIOENCODING=ascii:ignore python3 - <<'PY'
        import io
        from pathlib import Path

        Path('/tmp').mkdir(exist_ok=True)
        path = Path('/tmp/ocr.txt')
        path.write_bytes('/相册/系统/截图/33b3a106cdd8.png:\\n'.encode('utf-8'))
        print('path=' + path.read_text().strip())
        print('open=' + open('/tmp/ocr.txt').read().strip())
        print('io=' + io.open('/tmp/ocr.txt').read().strip())
        print('locale-kw=' + open('/tmp/ocr.txt', encoding='locale').read().strip())
        print('locale-pos=' + open('/tmp/ocr.txt', 'r', -1, 'locale').read().strip())
        written = Path('/tmp/中文-output.txt')
        written.write_text('中文内容')
        print('write=' + written.read_bytes().decode('utf-8'))
        print('explicit=' + open('/tmp/ocr.txt', encoding='ascii', errors='ignore').read().strip())
        blob = Path('/tmp/blob.bin')
        blob.write_bytes(b'\\xff\\x00msp')
        print('binary=' + repr(blob.read_bytes()))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, """
        path=/相册/系统/截图/33b3a106cdd8.png:
        open=/相册/系统/截图/33b3a106cdd8.png:
        io=/相册/系统/截图/33b3a106cdd8.png:
        locale-kw=/相册/系统/截图/33b3a106cdd8.png:
        locale-pos=/相册/系统/截图/33b3a106cdd8.png:
        write=中文内容
        explicit=////33b3a106cdd8.png:
        binary=b'\\xff\\x00msp'

        """)
    }
    func testCPythonEngineScriptEntrypointUsesVirtualWorkspaceWhenLibraryIsAvailable() async throws {
        guard let library = Self.localCPythonLibrary() else {
            throw XCTSkip("Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython script-entrypoint test.")
        }
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("tmp", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("""
        from pathlib import Path
        import os
        import subprocess
        import sys

        Path('/tmp/script-output.txt').write_text('script:' + sys.argv[1], encoding='utf-8')
        print('argv0=' + sys.argv[0])
        print('cwd=' + os.getcwd())
        print('read=' + Path('/tmp/script-output.txt').read_text(encoding='utf-8'))
        find_output = subprocess.check_output(
            ['find', '/tmp', '-maxdepth', '1', '-type', 'f'],
            text=True
        )
        print('find=' + ','.join(sorted(find_output.splitlines())))
        print('host=\(rootURL.path)/tmp/script-entry.py')
        """.utf8).write(to: rootURL.appendingPathComponent("tmp/script-entry.py"))

        let engine = try MSPCPythonEngine(
            library: .path(library.libraryURL),
            workspaceRootURL: rootURL,
            pythonHomeURL: library.homeURL
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
            .enable(.python(runtime: MSPPythonEmbeddedRuntime(engine: engine)))

        let result = await shell.run("python3 -S -E -I /tmp/script-entry.py value")

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        argv0=/tmp/script-entry.py
        cwd=/
        read=script:value
        find=/tmp/script-entry.py,/tmp/script-output.txt
        host=/tmp/script-entry.py

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("_msp_vfs"))
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("tmp/script-output.txt"), encoding: .utf8),
            "script:value"
        )
    }
}
