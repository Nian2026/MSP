import Foundation
import XCTest
import ModelShellProxy
@testable import MSPPythonRuntime

#if os(macOS)
extension MSPPythonHostProcessVFSTestsBytesAndMetadata {
    func testHostProcessPythonBytesPathsUseVirtualWorkspace() async throws {
        let pythonURL = try requireHostPython("host-process Python VFS bytes path test.")
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
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
    }

    func testHostProcessPythonBytesPathErrorsPreserveBytesFilenames() async throws {
        let pythonURL = try requireHostPython("host-process Python VFS bytes path error test.")
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
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
    }
}
#endif
