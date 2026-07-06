import Foundation
import XCTest
import ModelShellProxy
@testable import MSPPythonRuntime

#if os(macOS)
extension MSPPythonHostProcessVFSTestsPath {
    func testHostProcessPythonOpenHandleUnlinkDoesNotRestoreWorkspacePath() async throws {
        let pythonURL = try requireHostPython("host-process Python VFS unlink tests.")
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
        fd = os.open('/tmp/open-unlink-fd.txt', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.write(fd, b'left')
        print('fd-before-list=' + ','.join(sorted(os.listdir('/tmp'))))
        os.unlink('/tmp/open-unlink-fd.txt')
        print('fd-exists-after-unlink=' + str(Path('/tmp/open-unlink-fd.txt').exists()))
        print('fd-list-after-unlink=' + ','.join(sorted(os.listdir('/tmp'))))
        os.write(fd, b'-right')
        os.close(fd)
        print('fd-exists-after-close=' + str(Path('/tmp/open-unlink-fd.txt').exists()))
        print('fd-list-after-close=' + ','.join(sorted(os.listdir('/tmp'))))

        file = open('/tmp/open-unlink-file.txt', 'w', encoding='utf-8')
        file.write('alpha')
        file.flush()
        print('file-before-list=' + ','.join(sorted(os.listdir('/tmp'))))
        os.unlink('/tmp/open-unlink-file.txt')
        print('file-exists-after-unlink=' + str(Path('/tmp/open-unlink-file.txt').exists()))
        print('file-list-after-unlink=' + ','.join(sorted(os.listdir('/tmp'))))
        file.write('-omega')
        file.close()
        print('file-exists-after-close=' + str(Path('/tmp/open-unlink-file.txt').exists()))
        print('final-list=' + ','.join(sorted(os.listdir('/tmp'))))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        fd-before-list=open-unlink-fd.txt
        fd-exists-after-unlink=False
        fd-list-after-unlink=
        fd-exists-after-close=False
        fd-list-after-close=
        file-before-list=open-unlink-file.txt
        file-exists-after-unlink=False
        file-list-after-unlink=
        file-exists-after-close=False
        final-list=

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        let tmpURL = rootURL.appendingPathComponent("tmp")
        let tmpChildren = (try? FileManager.default.contentsOfDirectory(atPath: tmpURL.path)) ?? []
        XCTAssertEqual(tmpChildren, [])
    }
}
#endif
