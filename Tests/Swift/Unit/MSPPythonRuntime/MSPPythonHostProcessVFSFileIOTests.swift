import Foundation
import XCTest
import ModelShellProxy
@testable import MSPPythonRuntime

#if os(macOS)
extension MSPPythonHostProcessVFSTestsBytesAndMetadata {
    func testHostProcessPythonDefaultsVirtualTextFilesToUTF8() async throws {
        let pythonURL = try requireHostPython("host-process Python VFS tests.")
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
            .enable(.python(runtime: MSPPythonHostProcessRuntime(
                executableURL: pythonURL,
                workspaceRootURL: rootURL
            )))

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

    func testHostProcessPythonAnonymousOpenIterationKeepsVFSFileAlive() async throws {
        let pythonURL = try requireHostPython("host-process Python VFS tests.")
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

        Path('/tmp').mkdir(exist_ok=True)
        Path('/tmp/pool.txt').write_text('alpha\\nbeta\\n', encoding='utf-8')
        paths = [line.rstrip('\\n') for line in open('/tmp/pool.txt', encoding='utf-8')]
        print('paths=' + repr(paths))
        first = next(iter(open('/tmp/pool.txt', encoding='utf-8'))).strip()
        print('first=' + first)
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, """
        paths=['alpha', 'beta']
        first=alpha

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("msp-python-launcher.py"))
    }

    func testHostProcessPythonAppliesVirtualUmaskAndFlushesUnclosedVFSFiles() async throws {
        let pythonURL = try requireHostPython("host-process Python VFS tests.")
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
        import json
        import os
        import stat

        root = Path('pyglob')
        (root / 'sub').mkdir(parents=True, exist_ok=True)
        (root / 'a.txt').write_text('A\\n', encoding='utf-8')
        (root / 'sub' / 'b.txt').write_text('BB\\n', encoding='utf-8')
        os.chmod(root / 'sub' / 'b.txt', 0o600)
        leaked = open('payload.bin', 'wb')
        leaked.write(b'PAY\\x00LOAD')
        open('inline.bin', 'wb').write(b'INLINE')

        rows = []
        for path in [root, root / 'sub', root / 'a.txt', root / 'sub' / 'b.txt']:
            path_stat = path.lstat()
            rows.append([
                path.as_posix(),
                oct(stat.S_IMODE(path_stat.st_mode)),
                None if path.is_dir() else path_stat.st_size,
            ])
        print(json.dumps(rows, separators=(',', ':')))

        old_umask = os.umask(0)
        Path('wide-dir').mkdir()
        Path('wide-file.txt').write_text('W', encoding='utf-8')
        wide_dir = oct(stat.S_IMODE(Path('wide-dir').lstat().st_mode))
        wide_file = oct(stat.S_IMODE(Path('wide-file.txt').lstat().st_mode))
        Path('tool.sh').write_text('#!/bin/sh\\nexit 0\\n', encoding='utf-8')
        Path('tool.sh').chmod(0o755)
        tool_mode = oct(stat.S_IMODE(Path('tool.sh').lstat().st_mode))
        print('old-umask=%03o' % old_umask)
        print('wide=%s/%s' % (wide_dir, wide_file))
        print('tool=%s' % tool_mode)
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, """
        [["pyglob","0o755",null],["pyglob/sub","0o755",null],["pyglob/a.txt","0o644",2],["pyglob/sub/b.txt","0o600",3]]
        old-umask=022
        wide=0o777/0o666
        tool=0o755

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("msp-python-launcher.py"))
        XCTAssertEqual(
            try Data(contentsOf: rootURL.appendingPathComponent("payload.bin")),
            Data([0x50, 0x41, 0x59, 0x00, 0x4c, 0x4f, 0x41, 0x44])
        )
        XCTAssertEqual(
            try Data(contentsOf: rootURL.appendingPathComponent("inline.bin")),
            Data("INLINE".utf8)
        )
    }
}
#endif
