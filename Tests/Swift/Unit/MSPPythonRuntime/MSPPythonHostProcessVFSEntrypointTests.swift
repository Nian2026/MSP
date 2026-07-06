import Foundation
import XCTest
import ModelShellProxy
@testable import MSPPythonRuntime

#if os(macOS)
extension MSPPythonHostProcessVFSTestsBytesAndMetadata {
    func testHostProcessPythonEntrypointsAndPathlibStayVirtual() async throws {
        let pythonURL = try requireHostPython("host-process Python VFS tests.")
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let scriptURL = rootURL.appendingPathComponent("script.py")
        try Data("""
        from pathlib import Path
        import os
        import sys

        Path('/tmp/nested').mkdir(parents=True, exist_ok=True)
        Path('/tmp/script.txt').write_text('script:' + sys.argv[1], encoding='utf-8')
        fd = os.open('/tmp/nested/fd.txt', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.write(fd, b'fd-data')
        os.close(fd)
        print('script-argv0=' + sys.argv[0])
        print('script-read=' + Path('/tmp/script.txt').read_text(encoding='utf-8'))
        print('script-glob=' + ','.join(sorted(str(path) for path in Path('/tmp').glob('*.txt'))))
        print('script-rglob=' + ','.join(sorted(str(path) for path in Path('/tmp').rglob('*.txt'))))
        print('script-host-path=\(rootURL.path)/tmp/script.txt')
        """.utf8).write(to: scriptURL)

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
            .enable(.python(runtime: MSPPythonHostProcessRuntime(
                executableURL: pythonURL,
                workspaceRootURL: rootURL
            )))

        let command = await shell.run("""
        python3 -S -E -I -c "from pathlib import Path; Path('/tmp').mkdir(exist_ok=True); Path('/tmp/cmd.txt').write_text('cmd', encoding='utf-8'); print('cmd=' + Path('/tmp/cmd.txt').read_text(encoding='utf-8')); print('cmd-host=\(rootURL.path)/tmp/cmd.txt')"
        """)
        let script = await shell.run("python3 -S -E -I script.py value")

        XCTAssertEqual(command.stderr, "")
        XCTAssertEqual(command.exitCode, 0)
        XCTAssertEqual(command.stdout, """
        cmd=cmd
        cmd-host=/tmp/cmd.txt

        """)
        XCTAssertFalse((command.stdout + command.stderr).contains(rootURL.path))

        XCTAssertEqual(script.stderr, "")
        XCTAssertEqual(script.exitCode, 0)
        XCTAssertEqual(script.stdout, """
        script-argv0=script.py
        script-read=script:value
        script-glob=/tmp/cmd.txt,/tmp/script.txt
        script-rglob=/tmp/cmd.txt,/tmp/nested/fd.txt,/tmp/script.txt
        script-host-path=/tmp/script.txt

        """)
        XCTAssertFalse((script.stdout + script.stderr).contains(rootURL.path))
        XCTAssertFalse((script.stdout + script.stderr).contains("msp-python-launcher.py"))
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("tmp/script.txt"), encoding: .utf8),
            "script:value"
        )
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("tmp/nested/fd.txt"), encoding: .utf8),
            "fd-data"
        )
    }
}
#endif
