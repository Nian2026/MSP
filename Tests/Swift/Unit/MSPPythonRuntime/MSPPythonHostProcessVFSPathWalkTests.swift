import Foundation
import XCTest
import ModelShellProxy
@testable import MSPPythonRuntime

#if os(macOS)
extension MSPPythonHostProcessVFSTestsPath {
    func testHostProcessPythonGlobAndWalkStayVirtual() async throws {
        let pythonURL = try requireHostPython("host-process Python VFS glob/walk test.")
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
            .enable(.python(runtime: MSPPythonHostProcessRuntime(
                executableURL: pythonURL,
                workspaceRootURL: rootURL
            )))

        let result = await shell.run("""
        mkdir -p /tmp/glob/linktarget/nested
        printf link > /tmp/glob/linktarget/link.dat
        printf nested > /tmp/glob/linktarget/nested/deep.dat
        ln -s linktarget /tmp/glob/link-dir
        ln -s missing-target /tmp/glob/dangling-link
        ln -s /tmp/race-target /tmp/race-link-candidate
        python3 -S - <<'PY'
        from pathlib import Path
        import glob
        import os
        import shutil

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

        (root / 'race' / 'mutable').mkdir(parents=True)
        Path('/tmp/race-target/nested').mkdir(parents=True)
        Path('/tmp/race-target/nested/secret.txt').write_text('secret', encoding='utf-8')
        os.rename('/tmp/race-link-candidate', '/tmp/glob/race/link-candidate')
        fwalk_replaced_link_rows = []
        for dirpath, dirnames, filenames, dirfd in os.fwalk('/tmp/glob/race'):
            fwalk_replaced_link_rows.append((dirpath, sorted(dirnames), sorted(filenames)))
            if dirpath == '/tmp/glob/race':
                shutil.rmtree('/tmp/glob/race/mutable')
                os.rename('/tmp/glob/race/link-candidate', '/tmp/glob/race/mutable')
        print('fwalk-replaced-link-default=' + repr(sorted(fwalk_replaced_link_rows)))
        shutil.rmtree('/tmp/glob/race')
        shutil.rmtree('/tmp/race-target')

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
        fwalk-replaced-link-default=[('/tmp/glob/race', ['link-candidate', 'mutable'], [])]
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
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-materialized"))
        XCTAssertFalse((result.stdout + result.stderr).contains("subprocess-broker"))
    }
}
#endif
