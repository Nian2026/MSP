import Foundation
import XCTest
import ModelShellProxy
@testable import MSPPythonRuntime

#if os(macOS)
extension MSPPythonHostProcessVFSTestsPath {
    func testHostProcessPythonRenameReplaceEdgeCasesMatchCPythonShape() async throws {
        let pythonURL = try requireHostPython("host-process Python VFS rename/replace edge case test.")
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
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-materialized"))
    }
}
#endif
