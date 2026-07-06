import Foundation
import XCTest
import ModelShellProxy
import MSPApple
import MSPPythonEmbeddedRuntime

final class MSPCPythonEngineWorkspaceTestsPath: MSPPythonEmbeddedRuntimeTestCase {
    func testCPythonEnginePathPredicatesUseVirtualWorkspaceWhenLibraryIsAvailable() async throws {
        let fixture = try embeddedCPythonShell(
            skipMessage: "Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython VFS path predicate test."
        )
        defer { fixture.cleanup() }

        let result = await fixture.shell.run("""
        python3 - <<'PY'
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
        assertNoEmbeddedCPythonHostLeak(result.stdout + result.stderr, rootURL: fixture.rootURL)
    }

    func testCPythonEngineStatAndLstatFollowWorkspaceSymlinkSemanticsWhenLibraryIsAvailable() async throws {
        let fixture = try embeddedCPythonShell(
            skipMessage: "Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython VFS symlink stat test."
        )
        defer { fixture.cleanup() }

        let result = await fixture.shell.run("""
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
        python3 - <<'PY'
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
        assertNoEmbeddedCPythonHostLeak(result.stdout + result.stderr, rootURL: fixture.rootURL)
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-materialized"))
    }
    func testCPythonEngineGetcwdbUsesVirtualCWDWhenLibraryIsAvailable() async throws {
        let fixture = try embeddedCPythonShell(
            skipMessage: "Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython VFS getcwdb test."
        )
        defer { fixture.cleanup() }

        let result = await fixture.shell.run("""
        python3 - <<'PY'
        from pathlib import Path
        import os

        print('cwd-type=' + type(os.getcwd()).__name__)
        print('cwdb-type=' + type(os.getcwdb()).__name__)
        print('cwd=' + os.getcwd())
        print('cwdb=' + os.getcwdb().decode('utf-8'))
        Path('/tmp/中文').mkdir(parents=True, exist_ok=True)
        os.chdir('/tmp/中文')
        print('cwd2=' + os.getcwd())
        print('cwdb2=' + os.getcwdb().decode('utf-8'))
        os.chdir('..')
        print('cwd3=' + os.getcwd())
        print('cwdb3=' + os.getcwdb().decode('utf-8'))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        cwd-type=str
        cwdb-type=bytes
        cwd=/
        cwdb=/
        cwd2=/tmp/中文
        cwdb2=/tmp/中文
        cwd3=/tmp
        cwdb3=/tmp

        """)
        assertNoEmbeddedCPythonHostLeak(result.stdout + result.stderr, rootURL: fixture.rootURL)
    }
    func testCPythonEngineHomeAndExpanduserStayVirtualWhenLibraryIsAvailable() async throws {
        let fixture = try embeddedCPythonShell(
            skipMessage: "Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython VFS home/expanduser test."
        )
        defer { fixture.cleanup() }

        let result = await fixture.shell.run("""
        python3 - <<'PY'
        from pathlib import Path
        import os

        print('home-env=' + os.environ.get('HOME', ''))
        print('expanduser-tilde=' + os.path.expanduser('~'))
        print('expanduser-file=' + os.path.expanduser('~/a.txt'))
        print('expanduser-bytes=' + repr(os.path.expanduser(b'~/a.txt')))
        print('expanduser-named=' + os.path.expanduser('~root/a.txt'))
        print('expanduser-named-bytes=' + repr(os.path.expanduser(b'~root/a.txt')))
        print('path-home=' + str(Path.home()))
        print('path-expanduser=' + str(Path('~/a.txt').expanduser()))
        print('path-plain=' + str(Path('plain').expanduser()))
        try:
            Path('~root/a.txt').expanduser()
        except RuntimeError as error:
            print('path-named-error=' + type(error).__name__ + ':' + str(error))
        else:
            print('path-named-error=allowed')
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        home-env=/
        expanduser-tilde=/
        expanduser-file=/a.txt
        expanduser-bytes=b'/a.txt'
        expanduser-named=~root/a.txt
        expanduser-named-bytes=b'~root/a.txt'
        path-home=/
        path-expanduser=/a.txt
        path-plain=plain
        path-named-error=RuntimeError:Could not determine home directory.

        """)
        assertNoEmbeddedCPythonHostLeak(result.stdout + result.stderr, rootURL: fixture.rootURL)
        XCTAssertFalse((result.stdout + result.stderr).contains(NSHomeDirectory()))
        XCTAssertFalse((result.stdout + result.stderr).contains("/var/root"))
    }
    func testCPythonEngineGlobAndWalkStayVirtualWhenLibraryIsAvailable() async throws {
        let fixture = try embeddedCPythonShell(
            skipMessage: "Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython VFS glob/walk test."
        )
        defer { fixture.cleanup() }

        let result = await fixture.shell.run("""
        mkdir -p /tmp/glob/linktarget/nested
        printf link > /tmp/glob/linktarget/link.dat
        printf nested > /tmp/glob/linktarget/nested/deep.dat
        ln -s linktarget /tmp/glob/link-dir
        ln -s missing-target /tmp/glob/dangling-link
        python3 - <<'PY'
        from pathlib import Path
        import glob
        import os

        root = Path('/tmp/glob')
        (root / 'sub').mkdir(parents=True, exist_ok=True)
        (root / 'a.txt').write_text('alpha', encoding='utf-8')
        (root / 'sub' / 'b.txt').write_text('beta', encoding='utf-8')
        (root / 'sub' / 'c.md').write_text('gamma', encoding='utf-8')

        print('glob-abs=' + repr(sorted(glob.glob('/tmp/glob/*.txt'))))
        print('glob-rec=' + repr(sorted(glob.glob('/tmp/glob/**/*.txt', recursive=True))))
        print('iglob-rec=' + repr(sorted(glob.iglob('/tmp/glob/**/*.txt', recursive=True))))
        os.chdir('/tmp')
        print('glob-rel-cwd=' + repr(sorted(glob.glob('glob/**/*.txt', recursive=True))))
        os.chdir('/')
        print('glob-bytes=' + repr(sorted(glob.glob(b'/tmp/glob/*.txt'))))
        print('listdir-link-dir=' + repr(sorted(os.listdir('/tmp/glob/link-dir'))))
        print('scandir-link-dir=' + repr(sorted(
            (entry.path, entry.is_dir(), entry.is_file())
            for entry in os.scandir('/tmp/glob/link-dir')
        )))
        print('path-iterdir-link-dir=' + repr(sorted(path.as_posix() for path in Path('/tmp/glob/link-dir').iterdir())))
        print('path-glob-link-dir-star=' + repr(sorted(path.as_posix() for path in Path('/tmp/glob/link-dir').glob('*'))))
        print('path-rglob-link-dir-star=' + repr(sorted(path.as_posix() for path in Path('/tmp/glob/link-dir').rglob('*'))))
        print('path-glob-root-link-star=' + repr(sorted(path.as_posix() for path in Path('/tmp/glob').glob('link-dir/*'))))
        print('path-rglob-root-dat=' + repr(sorted(path.as_posix() for path in Path('/tmp/glob').rglob('*.dat'))))
        print('path-rglob-root-dat-recurse=' + repr(sorted(path.as_posix() for path in Path('/tmp/glob').rglob('*.dat', recurse_symlinks=True))))
        print('path-glob-root-starstar=' + repr(sorted(path.as_posix() for path in Path('/tmp/glob').glob('**'))))
        print('path-glob-root-starstar-recurse=' + repr(sorted(path.as_posix() for path in Path('/tmp/glob').glob('**', recurse_symlinks=True))))
        print('path-glob-root-starstar-dir=' + repr(sorted(path.as_posix() for path in Path('/tmp/glob').glob('**/'))))
        print('path-glob-root-starstar-dir-recurse=' + repr(sorted(path.as_posix() for path in Path('/tmp/glob').glob('**/', recurse_symlinks=True))))
        print('path-rglob-root-empty=' + repr(sorted(path.as_posix() for path in Path('/tmp/glob').rglob(''))))
        print('glob-link-dir-star=' + repr(sorted(glob.glob('/tmp/glob/link-dir/*'))))
        print('glob-link-dir-rec=' + repr(sorted(glob.glob('/tmp/glob/link-dir/**', recursive=True))))
        print('open-link-dir-child=' + (Path('/tmp/glob/link-dir/link.dat').read_text(encoding='utf-8')))
        print('stat-link-dir-child=' + str((Path('/tmp/glob/link-dir/link.dat').stat().st_size)))
        print('exists-link-dir-child=' + str((Path('/tmp/glob/link-dir/nested/deep.dat').exists())))

        walk_rows = []
        for dirpath, dirnames, filenames in os.walk('/tmp/glob'):
            walk_rows.append((dirpath, sorted(dirnames), sorted(filenames)))
        print('walk=' + repr(sorted(walk_rows)))

        walk_follow_rows = []
        for dirpath, dirnames, filenames in os.walk('/tmp/glob', followlinks=True):
            walk_follow_rows.append((dirpath, sorted(dirnames), sorted(filenames)))
        print('walk-followlinks=' + repr(sorted(walk_follow_rows)))

        bytes_walk_rows = []
        for dirpath, dirnames, filenames in os.walk(b'/tmp/glob'):
            bytes_walk_rows.append((dirpath, sorted(dirnames), sorted(filenames)))
        print('walk-bytes=' + repr(sorted(bytes_walk_rows)))

        fwalk_rows = []
        fwalk_stats = []
        for dirpath, dirnames, filenames, dirfd in os.fwalk('/tmp/glob'):
            fwalk_rows.append((dirpath, sorted(dirnames), sorted(filenames)))
            for name in sorted(filenames):
                try:
                    fwalk_stats.append((dirpath + '/' + name, os.stat(name, dir_fd=dirfd).st_size))
                except OSError as error:
                    fwalk_stats.append((dirpath + '/' + name, type(error).__name__ + ':' + str(getattr(error, 'filename', None))))
        print('fwalk=' + repr(sorted(fwalk_rows)))
        print('fwalk-stat=' + repr(sorted(fwalk_stats)))

        fwalk_follow_rows = []
        for dirpath, dirnames, filenames, dirfd in os.fwalk('/tmp/glob', follow_symlinks=True):
            fwalk_follow_rows.append((dirpath, sorted(dirnames), sorted(filenames)))
        print('fwalk-follow=' + repr(sorted(fwalk_follow_rows)))

        fwalk_bottom_rows = []
        for dirpath, dirnames, filenames, dirfd in os.fwalk('/tmp/glob', topdown=False):
            fwalk_bottom_rows.append((dirpath, sorted(dirnames), sorted(filenames)))
        print('fwalk-bottom=' + repr(fwalk_bottom_rows))

        tmp_fd = os.open('/tmp', os.O_RDONLY)
        try:
            fwalk_dirfd_rows = []
            for dirpath, dirnames, filenames, dirfd in os.fwalk('glob', dir_fd=tmp_fd):
                fwalk_dirfd_rows.append((dirpath, sorted(dirnames), sorted(filenames)))
            print('fwalk-dirfd=' + repr(sorted(fwalk_dirfd_rows)))
        finally:
            os.close(tmp_fd)

        fwalk_bytes_rows = []
        for dirpath, dirnames, filenames, dirfd in os.fwalk(b'/tmp/glob'):
            fwalk_bytes_rows.append((dirpath, sorted(dirnames), sorted(filenames)))
        print('fwalk-bytes=' + repr(sorted(fwalk_bytes_rows)))

        fwalk_link_root_rows = []
        for dirpath, dirnames, filenames, dirfd in os.fwalk('/tmp/glob/link-dir'):
            fwalk_link_root_rows.append((dirpath, sorted(dirnames), sorted(filenames)))
        print('fwalk-link-root=' + repr(fwalk_link_root_rows))

        fwalk_link_root_follow_rows = []
        for dirpath, dirnames, filenames, dirfd in os.fwalk('/tmp/glob/link-dir', follow_symlinks=True):
            fwalk_link_root_follow_rows.append((dirpath, sorted(dirnames), sorted(filenames)))
        print('fwalk-link-root-follow=' + repr(fwalk_link_root_follow_rows))

        fwalk_errors = []
        def on_fwalk_error(error):
            fwalk_errors.append((type(error).__name__, getattr(error, 'filename', None), str(error)))
        try:
            list(os.fwalk('/tmp/glob/missing', onerror=on_fwalk_error))
        except OSError as error:
            print('fwalk-missing=' + type(error).__name__ + ':' + str(getattr(error, 'filename', None)) + ':' + str(error))
        else:
            print('fwalk-missing=allowed')
        print('fwalk-errors=' + repr(fwalk_errors))

        path_walk_rows = []
        for dirpath, dirnames, filenames in root.walk():
            path_walk_rows.append((dirpath.as_posix(), sorted(dirnames), sorted(filenames)))
        print('path-walk=' + repr(path_walk_rows))

        path_walk_follow_rows = []
        for dirpath, dirnames, filenames in root.walk(follow_symlinks=True):
            path_walk_follow_rows.append((dirpath.as_posix(), sorted(dirnames), sorted(filenames)))
        print('path-walk-follow=' + repr(path_walk_follow_rows))

        path_walk_bottom_rows = []
        for dirpath, dirnames, filenames in root.walk(top_down=False):
            path_walk_bottom_rows.append((dirpath.as_posix(), sorted(dirnames), sorted(filenames)))
        print('path-walk-bottom=' + repr(path_walk_bottom_rows))

        path_walk_pruned_rows = []
        for dirpath, dirnames, filenames in root.walk():
            if dirpath == root:
                dirnames[:] = [name for name in dirnames if name != 'linktarget']
            path_walk_pruned_rows.append((dirpath.as_posix(), sorted(dirnames), sorted(filenames)))
        print('path-walk-prune=' + repr(path_walk_pruned_rows))

        path_walk_errors = []
        def on_path_walk_error(error):
            path_walk_errors.append((type(error).__name__, getattr(error, 'filename', None), str(error)))
        print('path-walk-missing=' + repr(list((root / 'missing').walk(on_error=on_path_walk_error))))
        print('path-walk-errors=' + repr(path_walk_errors))
        for label, action in [
            ('path-walk-positional', lambda: list(root.walk(False))),
            ('path-walk-bad-keyword', lambda: list(root.walk(foo=True))),
        ]:
            try:
                value = action()
            except Exception as error:
                print(label + '=' + type(error).__name__ + ':' + str(error))
            else:
                print(label + '=' + repr([
                    (path.as_posix(), sorted(dirnames), sorted(filenames))
                    for path, dirnames, filenames in value
                ]))

        (root / 'CaseDir').mkdir()
        (root / 'CaseDir' / 'MIXED.CASE').write_text('mixed', encoding='utf-8')
        (root / 'lower.case').write_text('lower', encoding='utf-8')
        print('path-glob-case-default=' + repr(sorted(path.as_posix() for path in root.glob('*.CASE'))))
        print('path-glob-case-false=' + repr(sorted(path.as_posix() for path in root.glob('*.CASE', case_sensitive=False))))
        print('path-glob-case-true=' + repr(sorted(path.as_posix() for path in root.glob('*.CASE', case_sensitive=True))))
        print('path-rglob-case-false=' + repr(sorted(path.as_posix() for path in root.rglob('*.CASE', case_sensitive=False))))
        print('path-rglob-case-true=' + repr(sorted(path.as_posix() for path in root.rglob('*.CASE', case_sensitive=True))))
        for label, action in [
            ('path-glob-positional-extra', lambda: list(root.glob('*', False))),
            ('path-rglob-positional-extra', lambda: list(root.rglob('*', False))),
            ('path-glob-unknown', lambda: list(root.glob('*', unknown=True))),
            ('path-rglob-bytes', lambda: list(root.rglob(b'*'))),
            ('path-glob-abs', lambda: list(root.glob('/tmp'))),
        ]:
            try:
                action()
            except Exception as error:
                print(label + '=' + type(error).__name__ + ':' + str(error))
            else:
                print(label + '=allowed')
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        glob-abs=['/tmp/glob/a.txt']
        glob-rec=['/tmp/glob/a.txt', '/tmp/glob/sub/b.txt']
        iglob-rec=['/tmp/glob/a.txt', '/tmp/glob/sub/b.txt']
        glob-rel-cwd=['glob/a.txt', 'glob/sub/b.txt']
        glob-bytes=[b'/tmp/glob/a.txt']
        listdir-link-dir=['link.dat', 'nested']
        scandir-link-dir=[('/tmp/glob/link-dir/link.dat', False, True), ('/tmp/glob/link-dir/nested', True, False)]
        path-iterdir-link-dir=['/tmp/glob/link-dir/link.dat', '/tmp/glob/link-dir/nested']
        path-glob-link-dir-star=['/tmp/glob/link-dir/link.dat', '/tmp/glob/link-dir/nested']
        path-rglob-link-dir-star=['/tmp/glob/link-dir/link.dat', '/tmp/glob/link-dir/nested', '/tmp/glob/link-dir/nested/deep.dat']
        path-glob-root-link-star=['/tmp/glob/link-dir/link.dat', '/tmp/glob/link-dir/nested']
        path-rglob-root-dat=['/tmp/glob/linktarget/link.dat', '/tmp/glob/linktarget/nested/deep.dat']
        path-rglob-root-dat-recurse=['/tmp/glob/link-dir/link.dat', '/tmp/glob/link-dir/nested/deep.dat', '/tmp/glob/linktarget/link.dat', '/tmp/glob/linktarget/nested/deep.dat']
        path-glob-root-starstar=['/tmp/glob', '/tmp/glob/a.txt', '/tmp/glob/dangling-link', '/tmp/glob/link-dir', '/tmp/glob/linktarget', '/tmp/glob/linktarget/link.dat', '/tmp/glob/linktarget/nested', '/tmp/glob/linktarget/nested/deep.dat', '/tmp/glob/sub', '/tmp/glob/sub/b.txt', '/tmp/glob/sub/c.md']
        path-glob-root-starstar-recurse=['/tmp/glob', '/tmp/glob/a.txt', '/tmp/glob/dangling-link', '/tmp/glob/link-dir', '/tmp/glob/link-dir/link.dat', '/tmp/glob/link-dir/nested', '/tmp/glob/link-dir/nested/deep.dat', '/tmp/glob/linktarget', '/tmp/glob/linktarget/link.dat', '/tmp/glob/linktarget/nested', '/tmp/glob/linktarget/nested/deep.dat', '/tmp/glob/sub', '/tmp/glob/sub/b.txt', '/tmp/glob/sub/c.md']
        path-glob-root-starstar-dir=['/tmp/glob', '/tmp/glob/linktarget', '/tmp/glob/linktarget/nested', '/tmp/glob/sub']
        path-glob-root-starstar-dir-recurse=['/tmp/glob', '/tmp/glob/link-dir', '/tmp/glob/link-dir/nested', '/tmp/glob/linktarget', '/tmp/glob/linktarget/nested', '/tmp/glob/sub']
        path-rglob-root-empty=['/tmp/glob', '/tmp/glob/linktarget', '/tmp/glob/linktarget/nested', '/tmp/glob/sub']
        glob-link-dir-star=['/tmp/glob/link-dir/link.dat', '/tmp/glob/link-dir/nested']
        glob-link-dir-rec=['/tmp/glob/link-dir/', '/tmp/glob/link-dir/link.dat', '/tmp/glob/link-dir/nested', '/tmp/glob/link-dir/nested/deep.dat']
        open-link-dir-child=link
        stat-link-dir-child=4
        exists-link-dir-child=True
        walk=[('/tmp/glob', ['link-dir', 'linktarget', 'sub'], ['a.txt', 'dangling-link']), ('/tmp/glob/linktarget', ['nested'], ['link.dat']), ('/tmp/glob/linktarget/nested', [], ['deep.dat']), ('/tmp/glob/sub', [], ['b.txt', 'c.md'])]
        walk-followlinks=[('/tmp/glob', ['link-dir', 'linktarget', 'sub'], ['a.txt', 'dangling-link']), ('/tmp/glob/link-dir', ['nested'], ['link.dat']), ('/tmp/glob/link-dir/nested', [], ['deep.dat']), ('/tmp/glob/linktarget', ['nested'], ['link.dat']), ('/tmp/glob/linktarget/nested', [], ['deep.dat']), ('/tmp/glob/sub', [], ['b.txt', 'c.md'])]
        walk-bytes=[(b'/tmp/glob', [b'link-dir', b'linktarget', b'sub'], [b'a.txt', b'dangling-link']), (b'/tmp/glob/linktarget', [b'nested'], [b'link.dat']), (b'/tmp/glob/linktarget/nested', [], [b'deep.dat']), (b'/tmp/glob/sub', [], [b'b.txt', b'c.md'])]
        fwalk=[('/tmp/glob', ['link-dir', 'linktarget', 'sub'], ['a.txt', 'dangling-link']), ('/tmp/glob/linktarget', ['nested'], ['link.dat']), ('/tmp/glob/linktarget/nested', [], ['deep.dat']), ('/tmp/glob/sub', [], ['b.txt', 'c.md'])]
        fwalk-stat=[('/tmp/glob/a.txt', 5), ('/tmp/glob/dangling-link', 'FileNotFoundError:dangling-link'), ('/tmp/glob/linktarget/link.dat', 4), ('/tmp/glob/linktarget/nested/deep.dat', 6), ('/tmp/glob/sub/b.txt', 4), ('/tmp/glob/sub/c.md', 5)]
        fwalk-follow=[('/tmp/glob', ['link-dir', 'linktarget', 'sub'], ['a.txt', 'dangling-link']), ('/tmp/glob/link-dir', ['nested'], ['link.dat']), ('/tmp/glob/link-dir/nested', [], ['deep.dat']), ('/tmp/glob/linktarget', ['nested'], ['link.dat']), ('/tmp/glob/linktarget/nested', [], ['deep.dat']), ('/tmp/glob/sub', [], ['b.txt', 'c.md'])]
        fwalk-bottom=[('/tmp/glob/linktarget/nested', [], ['deep.dat']), ('/tmp/glob/linktarget', ['nested'], ['link.dat']), ('/tmp/glob/sub', [], ['b.txt', 'c.md']), ('/tmp/glob', ['link-dir', 'linktarget', 'sub'], ['a.txt', 'dangling-link'])]
        fwalk-dirfd=[('glob', ['link-dir', 'linktarget', 'sub'], ['a.txt', 'dangling-link']), ('glob/linktarget', ['nested'], ['link.dat']), ('glob/linktarget/nested', [], ['deep.dat']), ('glob/sub', [], ['b.txt', 'c.md'])]
        fwalk-bytes=[(b'/tmp/glob', [b'link-dir', b'linktarget', b'sub'], [b'a.txt', b'dangling-link']), (b'/tmp/glob/linktarget', [b'nested'], [b'link.dat']), (b'/tmp/glob/linktarget/nested', [], [b'deep.dat']), (b'/tmp/glob/sub', [], [b'b.txt', b'c.md'])]
        fwalk-link-root=[]
        fwalk-link-root-follow=[('/tmp/glob/link-dir', ['nested'], ['link.dat']), ('/tmp/glob/link-dir/nested', [], ['deep.dat'])]
        fwalk-missing=FileNotFoundError:/tmp/glob/missing:[Errno 2] No such file or directory: '/tmp/glob/missing'
        fwalk-errors=[]
        path-walk=[('/tmp/glob', ['linktarget', 'sub'], ['a.txt', 'dangling-link', 'link-dir']), ('/tmp/glob/linktarget', ['nested'], ['link.dat']), ('/tmp/glob/linktarget/nested', [], ['deep.dat']), ('/tmp/glob/sub', [], ['b.txt', 'c.md'])]
        path-walk-follow=[('/tmp/glob', ['link-dir', 'linktarget', 'sub'], ['a.txt', 'dangling-link']), ('/tmp/glob/link-dir', ['nested'], ['link.dat']), ('/tmp/glob/link-dir/nested', [], ['deep.dat']), ('/tmp/glob/linktarget', ['nested'], ['link.dat']), ('/tmp/glob/linktarget/nested', [], ['deep.dat']), ('/tmp/glob/sub', [], ['b.txt', 'c.md'])]
        path-walk-bottom=[('/tmp/glob/linktarget/nested', [], ['deep.dat']), ('/tmp/glob/linktarget', ['nested'], ['link.dat']), ('/tmp/glob/sub', [], ['b.txt', 'c.md']), ('/tmp/glob', ['linktarget', 'sub'], ['a.txt', 'dangling-link', 'link-dir'])]
        path-walk-prune=[('/tmp/glob', ['sub'], ['a.txt', 'dangling-link', 'link-dir']), ('/tmp/glob/sub', [], ['b.txt', 'c.md'])]
        path-walk-missing=[]
        path-walk-errors=[('FileNotFoundError', '/tmp/glob/missing', "[Errno 2] No such file or directory: '/tmp/glob/missing'")]
        path-walk-positional=[('/tmp/glob/linktarget/nested', [], ['deep.dat']), ('/tmp/glob/linktarget', ['nested'], ['link.dat']), ('/tmp/glob/sub', [], ['b.txt', 'c.md']), ('/tmp/glob', ['linktarget', 'sub'], ['a.txt', 'dangling-link', 'link-dir'])]
        path-walk-bad-keyword=TypeError:Path.walk() got an unexpected keyword argument 'foo'
        path-glob-case-default=[]
        path-glob-case-false=['/tmp/glob/lower.case']
        path-glob-case-true=[]
        path-rglob-case-false=['/tmp/glob/CaseDir/MIXED.CASE', '/tmp/glob/lower.case']
        path-rglob-case-true=['/tmp/glob/CaseDir/MIXED.CASE']
        path-glob-positional-extra=TypeError:Path.glob() takes 2 positional arguments but 3 were given
        path-rglob-positional-extra=TypeError:Path.rglob() takes 2 positional arguments but 3 were given
        path-glob-unknown=TypeError:Path.glob() got an unexpected keyword argument 'unknown'
        path-rglob-bytes=TypeError:argument should be a str or an os.PathLike object where __fspath__ returns a str, not 'bytes'
        path-glob-abs=NotImplementedError:Non-relative patterns are unsupported

        """)
        assertNoEmbeddedCPythonHostLeak(result.stdout + result.stderr, rootURL: fixture.rootURL)
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-materialized"))
        XCTAssertFalse((result.stdout + result.stderr).contains("subprocess-broker"))
    }
    func testCPythonEnginePathlibIterdirStaysVirtualWhenLibraryIsAvailable() async throws {
        let fixture = try embeddedCPythonShell(
            skipMessage: "Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython VFS pathlib iterdir test."
        )
        defer { fixture.cleanup() }

        let result = await fixture.shell.run("""
        python3 - <<'PY'
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
            for fragment in ['vfs-materialized', 'materialized-', '\(fixture.rootURL.path)']
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
        assertNoEmbeddedCPythonHostLeak(result.stdout + result.stderr, rootURL: fixture.rootURL)
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-materialized"))
    }
    func testCPythonEnginePathlibMutationsStayVirtualWhenLibraryIsAvailable() async throws {
        let fixture = try embeddedCPythonShell(
            skipMessage: "Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython VFS pathlib mutation test."
        )
        defer { fixture.cleanup() }

        let result = await fixture.shell.run("""
        python3 - <<'PY'
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
        assertNoEmbeddedCPythonHostLeak(result.stdout + result.stderr, rootURL: fixture.rootURL)
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-materialized"))
    }

    func testCPythonEngineRenameReplaceEdgeCasesMatchCPythonShapeWhenLibraryIsAvailable() async throws {
        let fixture = try embeddedCPythonShell(
            skipMessage: "Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython VFS rename/replace edge case test."
        )
        defer { fixture.cleanup() }

        let result = await fixture.shell.run("""
        python3 - <<'PY'
        from pathlib import Path
        import errno
        import os

        root = Path('/tmp/rename-cases')
        root.mkdir(parents=True, exist_ok=True)

        def describe(label, action, expected_errno=None):
            try:
                value = action()
                print('%s=ok:%s:%s' % (label, type(value).__name__, value))
            except BaseException as error:
                errno_matches = expected_errno is None or error.errno == expected_errno
                print('%s=%s:%r:%r:%s' % (
                    label,
                    type(error).__name__,
                    getattr(error, 'filename', None),
                    getattr(error, 'filename2', None),
                    errno_matches,
                ))

        (root / 'file.txt').write_text('source', encoding='utf-8')
        (root / 'existing.txt').write_text('existing', encoding='utf-8')
        describe('rename-file-over-file', lambda: os.rename(root / 'file.txt', root / 'existing.txt'))
        print('rename-file-over-file-content=' + (root / 'existing.txt').read_text(encoding='utf-8'))

        (root / 'dir').mkdir()
        (root / 'file-to-dir.txt').write_text('file-to-dir', encoding='utf-8')
        describe('rename-file-to-dir', lambda: os.rename(root / 'file-to-dir.txt', root / 'dir'), errno.EISDIR)
        print('file-to-dir-preserved=' + (root / 'file-to-dir.txt').read_text(encoding='utf-8') + ':' + str((root / 'dir').is_dir()))

        (root / 'replace-file-to-dir.txt').write_text('replace-file-to-dir', encoding='utf-8')
        describe('replace-file-to-dir', lambda: os.replace(root / 'replace-file-to-dir.txt', root / 'dir'), errno.EISDIR)

        (root / 'dir-source').mkdir()
        (root / 'target-file.txt').write_text('target', encoding='utf-8')
        describe('rename-dir-to-file', lambda: os.rename(root / 'dir-source', root / 'target-file.txt'), errno.ENOTDIR)
        print('dir-to-file-preserved=' + str((root / 'dir-source').is_dir()) + ':' + (root / 'target-file.txt').read_text(encoding='utf-8'))

        (root / 'dir-empty-source').mkdir()
        (root / 'dir-empty-target').mkdir()
        describe('rename-dir-over-empty-dir', lambda: os.rename(root / 'dir-empty-source', root / 'dir-empty-target'))
        print('rename-dir-over-empty-dir-isdir=' + str((root / 'dir-empty-target').is_dir()))

        (root / 'dir-nonempty-source').mkdir()
        (root / 'dir-nonempty-target').mkdir()
        (root / 'dir-nonempty-target' / 'child.txt').write_text('child', encoding='utf-8')
        describe(
            'rename-dir-over-nonempty-dir',
            lambda: os.rename(root / 'dir-nonempty-source', root / 'dir-nonempty-target'),
            errno.ENOTEMPTY,
        )
        print('nonempty-preserved=' + str((root / 'dir-nonempty-source').is_dir()) + ':' + (root / 'dir-nonempty-target' / 'child.txt').read_text(encoding='utf-8'))

        (root / 'same.txt').write_text('same', encoding='utf-8')
        describe('rename-same', lambda: os.rename(root / 'same.txt', root / 'same.txt'))
        describe('replace-same', lambda: os.replace(root / 'same.txt', root / 'same.txt'))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        rename-file-over-file=ok:NoneType:None
        rename-file-over-file-content=source
        rename-file-to-dir=IsADirectoryError:'/tmp/rename-cases/file-to-dir.txt':'/tmp/rename-cases/dir':True
        file-to-dir-preserved=file-to-dir:True
        replace-file-to-dir=IsADirectoryError:'/tmp/rename-cases/replace-file-to-dir.txt':'/tmp/rename-cases/dir':True
        rename-dir-to-file=NotADirectoryError:'/tmp/rename-cases/dir-source':'/tmp/rename-cases/target-file.txt':True
        dir-to-file-preserved=True:target
        rename-dir-over-empty-dir=ok:NoneType:None
        rename-dir-over-empty-dir-isdir=True
        rename-dir-over-nonempty-dir=OSError:'/tmp/rename-cases/dir-nonempty-source':'/tmp/rename-cases/dir-nonempty-target':True
        nonempty-preserved=True:child
        rename-same=ok:NoneType:None
        replace-same=ok:NoneType:None

        """)
        assertNoEmbeddedCPythonHostLeak(result.stdout + result.stderr, rootURL: fixture.rootURL)
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-materialized"))
    }
}
