import Foundation
import XCTest
import ModelShellProxy
@testable import MSPPythonRuntime

#if os(macOS)
extension MSPPythonHostProcessVFSTestsPath {
    func testHostProcessPythonPathPredicatesUseVirtualWorkspace() async throws {
        let pythonURL = try requireHostPython("host-process Python VFS path predicate tests.")
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

        Path('/tmp').mkdir(exist_ok=True)
        Path('/dev').mkdir(exist_ok=True)
        Path('/tmp/vfs-predicate.txt').write_text('predicate-data', encoding='utf-8')
        print('lexists-file=' + str(os.path.lexists('/tmp/vfs-predicate.txt')))
        print('lexists-missing=' + str(os.path.lexists('/tmp/missing-predicate.txt')))
        print('lexists-dev=' + str(os.path.lexists('/dev')))
        print('ismount-root=' + str(os.path.ismount('/')))
        print('ismount-dev=' + str(os.path.ismount('/dev')))
        print('ismount-tmp=' + str(os.path.ismount('/tmp')))
        os.chdir('/')
        print('ismount-dot-root=' + str(os.path.ismount('.')))
        os.chdir('/tmp')
        print('ismount-dot-tmp=' + str(os.path.ismount('.')))
        fd = os.open('/tmp/vfs-predicate.txt', os.O_RDONLY)
        try:
            for label, action in [
                ('lexists-fd', lambda: os.path.lexists(fd)),
                ('islink-fd', lambda: os.path.islink(fd)),
                ('ismount-fd', lambda: os.path.ismount(fd)),
                ('abspath-fd', lambda: os.path.abspath(fd)),
                ('realpath-fd', lambda: os.path.realpath(fd)),
                ('relpath-fd', lambda: os.path.relpath(fd)),
                ('readlink-fd', lambda: os.readlink(fd)),
            ]:
                try:
                    action()
                except TypeError as error:
                    print(label + '=' + type(error).__name__)
                else:
                    print(label + '=allowed')
        finally:
            os.close(fd)
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        lexists-file=True
        lexists-missing=False
        lexists-dev=True
        ismount-root=True
        ismount-dev=False
        ismount-tmp=False
        ismount-dot-root=True
        ismount-dot-tmp=False
        lexists-fd=TypeError
        islink-fd=TypeError
        ismount-fd=TypeError
        abspath-fd=TypeError
        realpath-fd=TypeError
        relpath-fd=TypeError
        readlink-fd=TypeError

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
    }

    func testHostProcessPythonStatAndLstatFollowWorkspaceSymlinkSemantics() async throws {
        let pythonURL = try requireHostPython("host-process Python VFS symlink stat test.")
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
            .enable(.python(runtime: MSPPythonHostProcessRuntime(
                executableURL: pythonURL,
                workspaceRootURL: rootURL
            )))

        let result = await shell.run("""
        mkdir -p /tmp/symlink/dir
        printf target > /tmp/symlink/target.txt
        printf child > /tmp/symlink/dir/child.txt
        ln -s target.txt /tmp/symlink/link-file
        ln -s dir /tmp/symlink/link-dir
        ln -s /tmp/symlink/target.txt /tmp/symlink/link-abs-file
        ln -s missing.txt /tmp/symlink/dangling
        ln -s loop-b /tmp/symlink/loop-a
        ln -s loop-a /tmp/symlink/loop-b
        ln /tmp/symlink/target.txt /tmp/symlink/hard-file
        python3 -S - <<'PY'
        from pathlib import Path
        import os
        import stat

        root = Path('/tmp/symlink')

        def flags(value):
            return '%s:%s:%s' % (
                stat.S_ISREG(value.st_mode),
                stat.S_ISDIR(value.st_mode),
                stat.S_ISLNK(value.st_mode),
            )

        for name in ['link-file', 'link-dir', 'dangling']:
            path = root / name
            try:
                print(name + '-stat=' + flags(os.stat(path)))
            except OSError as error:
                print(name + '-stat-error=' + type(error).__name__ + ':' + str(error.filename))
            print(name + '-lstat=' + flags(os.lstat(path)))
            print(name + '-predicates=' + ':'.join([
                str(os.path.isfile(path)),
                str(os.path.isdir(path)),
                str(os.path.islink(path)),
                str(os.path.exists(path)),
                str(os.path.lexists(path)),
            ]))

        entries = {entry.name: entry for entry in os.scandir(root)}
        for name in ['link-file', 'link-dir', 'dangling']:
            entry = entries[name]
            for follow in [True, False]:
                try:
                    print(name + '-direntry-stat-' + str(follow) + '=' + flags(entry.stat(follow_symlinks=follow)))
                except OSError as error:
                    print(name + '-direntry-stat-' + str(follow) + '-error=' + type(error).__name__ + ':' + str(error.filename))
            print(name + '-direntry-predicates=' + ':'.join([
                str(entry.is_file()),
                str(entry.is_file(follow_symlinks=False)),
                str(entry.is_dir()),
                str(entry.is_dir(follow_symlinks=False)),
                str(entry.is_symlink()),
            ]))
        print('direntry-hard-inode=' + str(entries['target.txt'].inode() == entries['hard-file'].inode()))
        for label, action in [
            ('direntry-stat-positional', lambda: entries['link-file'].stat(False)),
            ('direntry-is-file-positional', lambda: entries['link-file'].is_file(False)),
            ('direntry-is-dir-keyword', lambda: entries['link-file'].is_dir(foo=True)),
        ]:
            try:
                action()
            except TypeError as error:
                print(label + '=' + str(error))

        print('realpath-link-file=' + os.path.realpath(root / 'link-file'))
        print('realpath-link-dir-child=' + os.path.realpath(root / 'link-dir' / 'child.txt'))
        print('realpath-link-abs-file=' + os.path.realpath(root / 'link-abs-file'))
        print('realpath-dangling=' + os.path.realpath(root / 'dangling'))
        print('realpath-loop=' + os.path.realpath(root / 'loop-a'))
        print('resolve-link-file=' + str((root / 'link-file').resolve()))
        print('resolve-link-dir-child=' + str((root / 'link-dir' / 'child.txt').resolve()))
        for label, action in [
            ('realpath-dangling-strict', lambda: os.path.realpath(root / 'dangling', strict=True)),
            ('resolve-dangling-strict', lambda: (root / 'dangling').resolve(strict=True)),
            ('realpath-loop-strict', lambda: os.path.realpath(root / 'loop-a', strict=True)),
            ('resolve-loop-strict', lambda: (root / 'loop-a').resolve(strict=True)),
            ('realpath-positional-strict', lambda: os.path.realpath(root / 'link-file', True)),
            ('realpath-unknown-keyword', lambda: os.path.realpath(root / 'link-file', foo=True)),
        ]:
            try:
                action()
            except (OSError, TypeError) as error:
                print(label + '=' + type(error).__name__ + ':' + str(getattr(error, 'filename', '') or '') + ':' + str(error))

        print('samefile-target-link=' + str(os.path.samefile(root / 'target.txt', root / 'link-file')))
        print('pathlib-samefile=' + str((root / 'link-file').samefile(root / 'target.txt')))
        print('pathlib-stat-link-dir=' + flags((root / 'link-dir').stat()))
        print('pathlib-lstat-link-dir=' + flags((root / 'link-dir').lstat()))
        print('samefile-target-hard=' + str(os.path.samefile(root / 'target.txt', root / 'hard-file')))
        print('samestat-target-hard=' + str(os.path.samestat(os.stat(root / 'target.txt'), os.stat(root / 'hard-file'))))
        print('pathlib-hard-samefile=' + str((root / 'hard-file').samefile(root / 'target.txt')))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        link-file-stat=True:False:False
        link-file-lstat=False:False:True
        link-file-predicates=True:False:True:True:True
        link-dir-stat=False:True:False
        link-dir-lstat=False:False:True
        link-dir-predicates=False:True:True:True:True
        dangling-stat-error=FileNotFoundError:/tmp/symlink/dangling
        dangling-lstat=False:False:True
        dangling-predicates=False:False:True:False:True
        link-file-direntry-stat-True=True:False:False
        link-file-direntry-stat-False=False:False:True
        link-file-direntry-predicates=True:False:False:False:True
        link-dir-direntry-stat-True=False:True:False
        link-dir-direntry-stat-False=False:False:True
        link-dir-direntry-predicates=False:False:True:False:True
        dangling-direntry-stat-True-error=FileNotFoundError:/tmp/symlink/dangling
        dangling-direntry-stat-False=False:False:True
        dangling-direntry-predicates=False:False:False:False:True
        direntry-hard-inode=True
        direntry-stat-positional=stat() takes no positional arguments
        direntry-is-file-positional=is_file() takes no positional arguments
        direntry-is-dir-keyword='foo' is an invalid keyword argument for is_dir()
        realpath-link-file=/tmp/symlink/target.txt
        realpath-link-dir-child=/tmp/symlink/dir/child.txt
        realpath-link-abs-file=/tmp/symlink/target.txt
        realpath-dangling=/tmp/symlink/missing.txt
        realpath-loop=/tmp/symlink/loop-a
        resolve-link-file=/tmp/symlink/target.txt
        resolve-link-dir-child=/tmp/symlink/dir/child.txt
        realpath-dangling-strict=FileNotFoundError:/tmp/symlink/missing.txt:[Errno 2] No such file or directory: '/tmp/symlink/missing.txt'
        resolve-dangling-strict=FileNotFoundError:/tmp/symlink/missing.txt:[Errno 2] No such file or directory: '/tmp/symlink/missing.txt'
        realpath-loop-strict=OSError:/tmp/symlink/loop-a:[Errno 62] Too many levels of symbolic links: '/tmp/symlink/loop-a'
        resolve-loop-strict=OSError:/tmp/symlink/loop-a:[Errno 62] Too many levels of symbolic links: '/tmp/symlink/loop-a'
        realpath-positional-strict=TypeError::realpath() takes 1 positional argument but 2 were given
        realpath-unknown-keyword=TypeError::realpath() got an unexpected keyword argument 'foo'
        samefile-target-link=True
        pathlib-samefile=True
        pathlib-stat-link-dir=False:True:False
        pathlib-lstat-link-dir=False:False:True
        samefile-target-hard=True
        samestat-target-hard=True
        pathlib-hard-samefile=True

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-materialized"))
    }
}
#endif
