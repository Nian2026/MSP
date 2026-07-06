import Foundation
import XCTest
import ModelShellProxy
@testable import MSPPythonRuntime

#if os(macOS)
extension MSPPythonHostProcessVFSTestsPath {
    func testHostProcessPythonGetcwdbUsesVirtualCWD() async throws {
        let pythonURL = try requireHostPython("host-process Python VFS getcwdb test.")
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
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
    }

    func testHostProcessPythonHomeAndExpanduserStayVirtual() async throws {
        let pythonURL = try requireHostPython("host-process Python VFS home/expanduser test.")
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
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains(NSHomeDirectory()))
        XCTAssertFalse((result.stdout + result.stderr).contains("/var/root"))
    }
}
#endif
