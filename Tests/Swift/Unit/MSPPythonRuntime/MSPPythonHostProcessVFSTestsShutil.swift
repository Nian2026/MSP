import Foundation
import XCTest
import ModelShellProxy
@testable import MSPPythonRuntime

#if os(macOS)
final class MSPPythonHostProcessVFSTestsShutil: MSPPythonRuntimeTestCase {
    func testHostProcessPythonShutilWhichAndCommandPathMetadataStayVirtual() async throws {
        let pythonURL = try requireHostPython("host-process Python VFS shutil.which test.")
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

        tool = Path('/tmp/workspace-tool')
        tool.write_text('#!/bin/sh\\nexit 0\\n', encoding='utf-8')
        tool.chmod(0o755)

        print('which-find=' + str(shutil.which('find')))
        print('which-find-custom=' + str(shutil.which('find', path='/usr/bin')))
        print('which-find-bin-custom=' + str(shutil.which('find', path='/bin:/usr/bin')))
        print('which-find-wrong-path=' + repr(shutil.which('find', path='/tmp')))
        print('which-cd=' + repr(shutil.which('cd')))
        print('which-missing=' + repr(shutil.which('definitely-missing-msp-command')))
        print('which-workspace=' + str(shutil.which('workspace-tool', path='/tmp')))
        find_stat = os.stat('/usr/bin/find')
        bin_find_stat = os.stat('/bin/find')
        print('find-exists=' + str(os.path.exists('/usr/bin/find')))
        print('bin-find-exists=' + str(os.path.exists('/bin/find')))
        print('find-isfile=' + str(os.path.isfile('/usr/bin/find')))
        print('find-access=' + repr((os.access('/usr/bin/find', os.F_OK), os.access('/usr/bin/find', os.X_OK), os.access('/usr/bin/find', os.W_OK))))
        print('bin-find-access=' + repr((os.access('/bin/find', os.F_OK), os.access('/bin/find', os.X_OK), os.access('/bin/find', os.W_OK))))
        print('wrong-find-access=' + str(os.access('/usr/local/bin/find', os.F_OK | os.X_OK)))
        print('find-stat=' + str(stat.S_ISREG(find_stat.st_mode)) + ':' + '%03o' % stat.S_IMODE(find_stat.st_mode))
        print('bin-find-stat=' + str(stat.S_ISREG(bin_find_stat.st_mode)) + ':' + '%03o' % stat.S_IMODE(bin_find_stat.st_mode))
        print('root-has-bin=' + str('bin' in os.listdir('/')))
        print('usr-list=' + repr(sorted(os.listdir('/usr'))))
        print('usrbin-has-find=' + str('find' in os.listdir('/usr/bin')))
        print('bin-has-find=' + str('find' in os.listdir('/bin')))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        which-find=/usr/bin/find
        which-find-custom=/usr/bin/find
        which-find-bin-custom=/bin/find
        which-find-wrong-path=None
        which-cd=None
        which-missing=None
        which-workspace=/tmp/workspace-tool
        find-exists=True
        bin-find-exists=True
        find-isfile=True
        find-access=(True, True, False)
        bin-find-access=(True, True, False)
        wrong-find-access=False
        find-stat=True:755
        bin-find-stat=True:755
        root-has-bin=True
        usr-list=['bin']
        usrbin-has-find=True
        bin-has-find=True

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-materialized"))
    }

    func testHostProcessPythonShutilDirectoryDestinationsStayVirtual() async throws {
        let pythonURL = try requireHostPython("host-process Python VFS shutil directory destination test.")
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
        import shutil

        root = Path('/tmp/shutil')
        target = root / 'target'
        target.mkdir(parents=True, exist_ok=True)
        (root / 'copy.txt').write_text('copy', encoding='utf-8')
        (root / 'copy2.txt').write_text('copy2', encoding='utf-8')
        (root / 'move.txt').write_text('move', encoding='utf-8')
        (root / 'bytes.bin').write_bytes(b'bytes')

        copy_result = shutil.copy('/tmp/shutil/copy.txt', '/tmp/shutil/target')
        copy2_result = shutil.copy2(root / 'copy2.txt', target)
        move_result = shutil.move('/tmp/shutil/move.txt', '/tmp/shutil/target')
        bytes_result = shutil.copy(b'/tmp/shutil/bytes.bin', b'/tmp/shutil/target')

        print('copy=' + copy_result + ':' + Path(copy_result).read_text(encoding='utf-8'))
        print('copy2=' + copy2_result + ':' + Path(copy2_result).read_text(encoding='utf-8'))
        print('move=' + move_result + ':' + Path(move_result).read_text(encoding='utf-8'))
        print('move-source-exists=' + str((root / 'move.txt').exists()))
        print('bytes=' + repr(bytes_result) + ':' + open(bytes_result, 'rb').read().decode('utf-8'))

        tree = root / 'tree'
        (tree / 'nested').mkdir(parents=True)
        (tree / 'nested' / 'note.txt').write_text('tree-note', encoding='utf-8')
        tree_result = shutil.copytree('/tmp/shutil/tree', '/tmp/shutil/copied-tree')
        print('copytree=' + tree_result + ':' + Path('/tmp/shutil/copied-tree/nested/note.txt').read_text(encoding='utf-8'))
        shutil.rmtree('/tmp/shutil/copied-tree')
        print('rmtree-exists=' + str(Path('/tmp/shutil/copied-tree').exists()))
        shutil.rmtree('/tmp/shutil/missing-tree', ignore_errors=True)
        print('rmtree-ignore=ok')

        same_move_path = root / 'move-same.txt'
        same_move_path.write_text('same', encoding='utf-8')
        same_move_result = shutil.move(same_move_path, same_move_path)
        print('move-same=' + type(same_move_result).__name__ + ':' + str(same_move_result) + ':' + same_move_path.read_text(encoding='utf-8'))

        move_dir = root / 'move-dir'
        (move_dir / 'sub').mkdir(parents=True)
        try:
            shutil.move(move_dir, move_dir / 'sub')
        except shutil.Error as error:
            print('move-dir-into-self=' + type(error).__name__ + ':' + str(error))
        else:
            print('move-dir-into-self=allowed')

        (root / 'conflict.txt').write_text('conflict', encoding='utf-8')
        (target / 'conflict.txt').write_text('existing', encoding='utf-8')
        try:
            shutil.move('/tmp/shutil/conflict.txt', '/tmp/shutil/target')
        except shutil.Error as error:
            print('move-conflict=' + type(error).__name__ + ':' + str(error))
        else:
            print('move-conflict=allowed')
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        copy=/tmp/shutil/target/copy.txt:copy
        copy2=/tmp/shutil/target/copy2.txt:copy2
        move=/tmp/shutil/target/move.txt:move
        move-source-exists=False
        bytes=b'/tmp/shutil/target/bytes.bin':bytes
        copytree=/tmp/shutil/copied-tree:tree-note
        rmtree-exists=False
        rmtree-ignore=ok
        move-same=PosixPath:/tmp/shutil/move-same.txt:same
        move-dir-into-self=Error:Cannot move a directory '/tmp/shutil/move-dir' into itself '/tmp/shutil/move-dir/sub'.
        move-conflict=Error:Destination path '/tmp/shutil/target/conflict.txt' already exists

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-materialized"))
    }

    func testHostProcessPythonShutilCopystatHandlesVirtualPlatformFields() async throws {
        let pythonURL = try requireHostPython("host-process Python VFS shutil copystat test.")
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

        root = Path('/tmp/copystat')
        root.mkdir(parents=True, exist_ok=True)
        source = root / 'source.txt'
        destination = root / 'destination.txt'
        source.write_text('source', encoding='utf-8')
        destination.write_text('destination', encoding='utf-8')
        os.chmod(source, 0o640)

        source_stat = os.stat(source)
        print('source-has-flags=' + str(hasattr(source_stat, 'st_flags')))
        print('source-flags=' + str(getattr(source_stat, 'st_flags', 0)))
        shutil.copystat(source, destination)
        destination_stat = os.stat(destination)
        print('copystat=ok')
        print('destination-mode=%03o' % stat.S_IMODE(destination_stat.st_mode))
        print('destination-flags=' + str(getattr(destination_stat, 'st_flags', 0)))
        print('destination-read=' + destination.read_text(encoding='utf-8'))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        source-has-flags=True
        source-flags=0
        copystat=ok
        destination-mode=640
        destination-flags=0
        destination-read=destination

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-materialized"))
    }

    func testHostProcessPythonShutilCopyMetadataAndSameFileStayVirtual() async throws {
        let pythonURL = try requireHostPython("host-process Python VFS shutil copy metadata test.")
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

        root = Path('/tmp/shutil-copy-meta')
        root.mkdir(parents=True, exist_ok=True)
        source = root / 'source.txt'
        source.write_text('alpha', encoding='utf-8')
        os.chmod(source, 0o640)
        os.utime(source, (1111111111, 1111111111))

        copyfile_result = shutil.copyfile(source, root / 'copyfile.txt')
        print('copyfile-result=' + type(copyfile_result).__name__ + ':' + str(copyfile_result) + ':' + copyfile_result.read_text(encoding='utf-8'))

        bytes_result = shutil.copyfile(b'/tmp/shutil-copy-meta/source.txt', b'/tmp/shutil-copy-meta/bytes.txt')
        print('copyfile-bytes=' + type(bytes_result).__name__ + ':' + repr(bytes_result) + ':' + Path('/tmp/shutil-copy-meta/bytes.txt').read_text(encoding='utf-8'))

        try:
            shutil.copyfile(source, source)
        except shutil.SameFileError as error:
            print('copyfile-same=' + type(error).__name__ + ':' + str('same file' in str(error)) + ':' + source.read_text(encoding='utf-8'))
        else:
            print('copyfile-same=allowed')

        directory = root / 'directory'
        directory.mkdir()
        try:
            shutil.copyfile(source, directory)
        except IsADirectoryError as error:
            print('copyfile-dir=' + type(error).__name__ + ':' + str(error.filename))
        else:
            print('copyfile-dir=allowed')

        copy_result = shutil.copy(source, root / 'copy.txt')
        copy_stat = os.stat(copy_result)
        print('copy-result=' + type(copy_result).__name__ + ':' + str(copy_result) + ':' + '%03o' % stat.S_IMODE(copy_stat.st_mode) + ':' + str(int(copy_stat.st_mtime) == 1111111111))

        copy_dir_result = shutil.copy(source, directory)
        print('copy-dir-result=' + type(copy_dir_result).__name__ + ':' + copy_dir_result + ':' + Path(copy_dir_result).read_text(encoding='utf-8'))

        copy2_result = shutil.copy2(source, root / 'copy2.txt')
        copy2_stat = os.stat(copy2_result)
        print('copy2-result=' + type(copy2_result).__name__ + ':' + str(copy2_result) + ':' + '%03o' % stat.S_IMODE(copy2_stat.st_mode) + ':' + str(int(copy2_stat.st_mtime)))

        os.utime(root / 'copyfile.txt', ns=(222000000000, 333000000000))
        print('utime-ns=' + str(int(os.stat(root / 'copyfile.txt').st_mtime)))
        try:
            os.utime(root / 'copyfile.txt', (1, 2), ns=(3, 4))
        except ValueError as error:
            print('utime-both=' + type(error).__name__ + ':' + str(error))
        else:
            print('utime-both=allowed')
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        copyfile-result=PosixPath:/tmp/shutil-copy-meta/copyfile.txt:alpha
        copyfile-bytes=bytes:b'/tmp/shutil-copy-meta/bytes.txt':alpha
        copyfile-same=SameFileError:True:alpha
        copyfile-dir=IsADirectoryError:/tmp/shutil-copy-meta/directory
        copy-result=PosixPath:/tmp/shutil-copy-meta/copy.txt:640:False
        copy-dir-result=str:/tmp/shutil-copy-meta/directory/source.txt:alpha
        copy2-result=PosixPath:/tmp/shutil-copy-meta/copy2.txt:640:1111111111
        utime-ns=333
        utime-both=ValueError:utime: you may specify either 'times' or 'ns' but not both

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-materialized"))
    }

    func testHostProcessPythonShutilTreeSemanticsStayVirtual() async throws {
        let pythonURL = try requireHostPython("host-process Python VFS shutil tree semantics test.")
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
        import shutil

        root = Path('/tmp/shutil-tree')
        src = root / 'src'
        (src / 'nested').mkdir(parents=True)
        (src / 'keep.txt').write_text('keep', encoding='utf-8')
        (src / 'skip.txt').write_text('skip', encoding='utf-8')
        (src / 'nested' / 'note.txt').write_text('note', encoding='utf-8')

        existing = root / 'existing'
        existing.mkdir(parents=True)
        (existing / 'old.txt').write_text('old', encoding='utf-8')
        try:
            shutil.copytree(src, existing)
        except FileExistsError as error:
            print('exists=' + type(error).__name__ + ':' + str(error.filename))
        else:
            print('exists=allowed')

        ignore_seen = []
        def ignore(path, names):
            ignore_seen.append(type(path).__name__ + ':' + str(path) + ':' + ','.join(sorted(names)))
            return {'skip.txt'} if str(path) == '/tmp/shutil-tree/src' else set()

        merge_result = shutil.copytree(src, existing, dirs_exist_ok=True, ignore=ignore)
        merged = sorted(entry.relative_to(existing).as_posix() for entry in existing.rglob('*'))
        print('merge=' + type(merge_result).__name__ + ':' + str(merge_result) + ':' + '|'.join(merged))
        print('ignore=' + ';'.join(sorted(ignore_seen)))

        calls = []
        def copy_function(source, destination):
            calls.append(type(source).__name__ + '>' + type(destination).__name__ + ':' + source + '->' + destination)
            return shutil.copy2(source, destination)

        path_result = shutil.copytree(src, root / 'path-dst', copy_function=copy_function)
        print('path-result=' + type(path_result).__name__ + ':' + str(path_result))
        print('copy-function=' + '|'.join(sorted(calls)))

        bytes_result = shutil.copytree(b'/tmp/shutil-tree/src', b'/tmp/shutil-tree/bytes-dst')
        print('bytes-result=' + repr(bytes_result))

        (root / 'file-dst').write_text('plain-destination', encoding='utf-8')
        try:
            shutil.copytree(src, root / 'file-dst', dirs_exist_ok=True)
        except FileExistsError as error:
            print('file-dst=' + type(error).__name__ + ':' + str(error.filename))
        else:
            print('file-dst=allowed')

        plain_file = root / 'plain.txt'
        plain_file.write_text('plain', encoding='utf-8')
        try:
            shutil.rmtree(plain_file)
        except NotADirectoryError as error:
            print('rmtree-file=' + type(error).__name__ + ':' + str(error.errno == errno.ENOTDIR) + ':' + type(error.filename).__name__ + ':' + str(error.filename))
        else:
            print('rmtree-file=allowed')
        print('rmtree-file-exists=' + str(plain_file.exists()))
        shutil.rmtree(plain_file, ignore_errors=True)
        print('rmtree-ignore-file=' + str(plain_file.exists()))

        seen = []
        def onerror(function, path, exc_info):
            seen.append(type(path).__name__ + ':' + str(path) + ':' + exc_info[0].__name__)

        shutil.rmtree(root / 'missing', onerror=onerror)
        print('rmtree-onerror=' + ';'.join(seen))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        exists=FileExistsError:/tmp/shutil-tree/existing
        merge=PosixPath:/tmp/shutil-tree/existing:keep.txt|nested|nested/note.txt|old.txt
        ignore=str:/tmp/shutil-tree/src/nested:note.txt;str:/tmp/shutil-tree/src:keep.txt,nested,skip.txt
        path-result=PosixPath:/tmp/shutil-tree/path-dst
        copy-function=str>str:/tmp/shutil-tree/src/keep.txt->/tmp/shutil-tree/path-dst/keep.txt|str>str:/tmp/shutil-tree/src/nested/note.txt->/tmp/shutil-tree/path-dst/nested/note.txt|str>str:/tmp/shutil-tree/src/skip.txt->/tmp/shutil-tree/path-dst/skip.txt
        bytes-result=b'/tmp/shutil-tree/bytes-dst'
        file-dst=FileExistsError:/tmp/shutil-tree/file-dst
        rmtree-file=NotADirectoryError:True:PosixPath:/tmp/shutil-tree/plain.txt
        rmtree-file-exists=True
        rmtree-ignore-file=True
        rmtree-onerror=PosixPath:/tmp/shutil-tree/missing:FileNotFoundError

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-materialized"))
    }
}
#endif
