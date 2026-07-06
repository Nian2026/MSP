import Foundation
import XCTest
import ModelShellProxy
import MSPApple
import MSPPythonEmbeddedRuntime

final class MSPCPythonEngineWorkspaceTests: MSPPythonEmbeddedRuntimeTestCase {
    func testCPythonEngineRunsInlineCommandAndWorkspaceSideEffectWhenLibraryIsAvailable() async throws {
        guard let library = Self.localCPythonLibrary() else {
            throw XCTSkip("Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython engine test.")
        }
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let engine = try MSPCPythonEngine(
            library: .path(library.libraryURL),
            workspaceRootURL: rootURL,
            pythonHomeURL: library.homeURL
        )
        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
            .enable(.python(runtime: MSPPythonEmbeddedRuntime(engine: engine)))

        let result = await shell.run("python3 -c 'import sys; print(sys.argv); print(\"ERR\", file=sys.stderr)' a b")

        XCTAssertEqual(result.stdout, "['-c', 'a', 'b']\n")
        XCTAssertEqual(result.stderr, "ERR\n")
        XCTAssertEqual(result.exitCode, 0)

        let pipedInput = await shell.run(
            "printf 'pipe-data' | python3 -S -E -I -c 'import sys; print(sys.stdin.read())'"
        )

        XCTAssertEqual(pipedInput.stdout, "pipe-data\n")
        XCTAssertEqual(pipedInput.stderr, "")
        XCTAssertEqual(pipedInput.exitCode, 0)

        let workspaceResult = await shell.run("""
        python3 - <<'PY'
        from pathlib import Path
        Path("out.txt").write_text("ok")
        print(Path("out.txt").read_text())
        PY
        """)

        XCTAssertEqual(workspaceResult.stdout, "ok\n")
        XCTAssertEqual(workspaceResult.stderr, "")
        XCTAssertEqual(workspaceResult.exitCode, 0)
        XCTAssertEqual(
            try String(contentsOf: rootURL.appendingPathComponent("out.txt"), encoding: .utf8),
            "ok"
        )

        let outputVirtualization = await shell.run("""
        python3 - <<'PY'
        import os
        import sys
        print("STDOUT_PATH=\(rootURL.path)/tmp/output.txt")
        print("STDERR_PATH=\(rootURL.path)/tmp/error.txt", file=sys.stderr)
        print("INTERNAL_ENV=" + ",".join(sorted(key for key in os.environ if key.startswith("MSP_PYTHON_"))))
        sys.stdout.flush()
        sys.stderr.flush()
        sys.stdout.buffer.write(b"BUFFER_STDOUT=\(rootURL.path)/tmp/buffer.txt\\n")
        sys.stderr.buffer.write(b"BUFFER_STDERR=\(rootURL.path)/tmp/buffer.txt\\n")
        PY
        """)

        XCTAssertEqual(outputVirtualization.stdout, """
        STDOUT_PATH=/tmp/output.txt
        INTERNAL_ENV=
        BUFFER_STDOUT=/tmp/buffer.txt

        """)
        XCTAssertEqual(outputVirtualization.stderr, """
        STDERR_PATH=/tmp/error.txt
        BUFFER_STDERR=/tmp/buffer.txt

        """)
        XCTAssertEqual(outputVirtualization.exitCode, 0)
        XCTAssertFalse((outputVirtualization.stdout + outputVirtualization.stderr).contains(rootURL.path))
        XCTAssertFalse((outputVirtualization.stdout + outputVirtualization.stderr).contains("vfs-broker"))
        XCTAssertFalse((outputVirtualization.stdout + outputVirtualization.stderr).contains("subprocess-broker"))
        XCTAssertFalse((outputVirtualization.stdout + outputVirtualization.stderr).contains("_msp_vfs"))

    }
    func testCPythonEngineOpenHandleUnlinkDoesNotRestoreWorkspacePathWhenLibraryIsAvailable() async throws {
        let fixture = try embeddedCPythonShell(
            skipMessage: "Set MSP_CPYTHON_LIBRARY_PATH to run the dynamic CPython VFS unlink test."
        )
        defer { fixture.cleanup() }

        let result = await fixture.shell.run("""
        python3 - <<'PY'
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
        assertNoEmbeddedCPythonHostLeak(result.stdout + result.stderr, rootURL: fixture.rootURL)
        let tmpURL = fixture.rootURL.appendingPathComponent("tmp")
        let tmpChildren = (try? FileManager.default.contentsOfDirectory(atPath: tmpURL.path)) ?? []
        XCTAssertEqual(tmpChildren, [])
    }
}
