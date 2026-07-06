import Foundation
import XCTest
import ModelShellProxy
@testable import MSPPythonRuntime

#if os(macOS)
final class MSPPythonHostProcessVFSTestsSecurity: MSPPythonRuntimeTestCase {
    func testHostProcessPythonVFSGuardsImportsLinksPathStringsAndRealPathEscapes() async throws {
        let pythonURL = try requireHostPython("host-process Python VFS guard tests.")
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let hostSecretURL = rootURL.appendingPathComponent("host-secret.txt")
        let nestedURL = rootURL.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        try Data("secret\n".utf8).write(to: hostSecretURL)

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
            .enable(.python(runtime: MSPPythonHostProcessRuntime(
                executableURL: pythonURL,
                workspaceRootURL: rootURL
            )))

        let result = await shell.run("""
        python3 -S - <<'PY'
        from pathlib import Path
        import builtins
        import importlib
        import os
        import sys

        for name in ["pip", "ensurepip", "venv", "multiprocessing"]:
            for label, loader in [("import", __import__), ("import_module", importlib.import_module)]:
                try:
                    loader(name)
                except PermissionError:
                    print(label + ":" + name + "=blocked")
                else:
                    print(label + ":" + name + "=allowed")

        Path('/tmp').mkdir(exist_ok=True)
        Path('/tmp/source.txt').write_text('ok', encoding='utf-8')
        print('str-path=' + str(Path('\(rootURL.path)/tmp/source.txt')))

        for label, call in [
            ("symlink", lambda: os.symlink('/tmp/source.txt', '/tmp/link.txt')),
            ("link", lambda: os.link('/tmp/source.txt', '/tmp/hard.txt')),
        ]:
            try:
                call()
            except PermissionError:
                print(label + '=blocked')
            else:
                print(label + '=allowed')

        originals = getattr(sys, '__msp_python_vfs_originals__')
        original_open = originals['builtins_open']
        original_os_open = originals['os_open']

        def report(label, action):
            try:
                action()
            except PermissionError:
                print(label + '=blocked')
            else:
                print(label + '=allowed')

        report('real-open-absolute', lambda: original_open('\(hostSecretURL.path)', encoding='utf-8').read())
        report('real-open-relative', lambda: original_open('host-secret.txt', encoding='utf-8').read())
        report('real-open-dotdot', lambda: original_open('nested/../host-secret.txt', encoding='utf-8').read())
        report(
            'opener-relative',
            lambda: open(
                'host-secret.txt',
                'r',
                opener=lambda path, flags: original_os_open(path, flags)
            ).read()
        )
        report(
            'opener-absolute',
            lambda: open(
                '\(hostSecretURL.path)',
                'r',
                opener=lambda path, flags: original_os_open(path, flags)
            ).read()
        )
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, """
        import:pip=blocked
        import_module:pip=blocked
        import:ensurepip=blocked
        import_module:ensurepip=blocked
        import:venv=blocked
        import_module:venv=blocked
        import:multiprocessing=blocked
        import_module:multiprocessing=blocked
        str-path=/tmp/source.txt
        symlink=blocked
        link=blocked
        real-open-absolute=blocked
        real-open-relative=blocked
        real-open-dotdot=blocked
        opener-relative=blocked
        opener-absolute=blocked

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("msp-python-launcher.py"))
    }
}
#endif
