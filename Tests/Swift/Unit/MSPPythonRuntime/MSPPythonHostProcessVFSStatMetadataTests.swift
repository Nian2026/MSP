import Foundation
import XCTest
import ModelShellProxy
@testable import MSPPythonRuntime

#if os(macOS)
extension MSPPythonHostProcessVFSTestsBytesAndMetadata {
    func testHostProcessPythonStatAcceptsVirtualFileDescriptor() async throws {
        let pythonURL = try requireHostPython("host-process Python VFS fd stat tests.")
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
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
    }

    func testHostProcessPythonUtimeRejectsNonFiniteValuesWithoutBrokerTimeout() async throws {
        let pythonURL = try requireHostPython("host-process Python VFS non-finite utime test.")
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
        import math
        import os
        import signal
        import time

        class LocalTimeout(Exception):
            pass

        def alarm_handler(signum, frame):
            raise LocalTimeout("local alarm")

        old_handler = signal.signal(signal.SIGALRM, alarm_handler)
        target = Path('/tmp/nonfinite-utime.txt')
        target.write_text('data', encoding='utf-8')
        for label, value in [('nan', math.nan), ('inf', math.inf), ('ninf', -math.inf)]:
            started = time.monotonic()
            signal.alarm(5)
            try:
                os.utime(target, (value, value))
            except Exception as error:
                elapsed_ok = time.monotonic() - started < 5.0
                timed_out = 'timed out' in str(error)
                print(label + '=' + type(error).__name__ + ':' + str(timed_out) + ':' + str(elapsed_ok))
            else:
                print(label + '=allowed')
            finally:
                signal.alarm(0)
        signal.signal(signal.SIGALRM, old_handler)
        print('still-readable=' + target.read_text(encoding='utf-8'))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        nan=ValueError:False:True
        inf=OverflowError:False:True
        ninf=OverflowError:False:True
        still-readable=data

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
    }
}
#endif
