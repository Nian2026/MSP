import Foundation
import XCTest
import ModelShellProxy
@testable import MSPPythonRuntime

final class MSPPythonSubprocessShimTests: XCTestCase {
    func testHostProcessPythonCommunicateAfterPartialReadWithMergedStderrReturnsUnreadOutput() async throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/python3") else {
            throw XCTSkip("/usr/bin/python3 is required for host-process Python VFS tests.")
        }
        let rootURL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let shell = try ModelShellProxy.iOS(workspaceURL: rootURL)
            .enable(.posixCore)
            .enable(.python(runtime: MSPPythonHostProcessRuntime(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                workspaceRootURL: rootURL
            )))

        let result = await shell.run("""
        python3 -S - <<'PY'
        import subprocess

        process = subprocess.Popen(
            "printf out; printf err >&2",
            shell=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True
        )
        first = process.stdout.read(1)
        rest, error = process.communicate(timeout=5)
        print("partial-communicate=%r" % ((first, rest, error, process.returncode),))
        PY
        """)

        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, """
        partial-communicate=('o', 'uterr', None, 0)

        """)
        XCTAssertFalse((result.stdout + result.stderr).contains(rootURL.path))
        XCTAssertFalse((result.stdout + result.stderr).contains("subprocess-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("vfs-broker"))
        XCTAssertFalse((result.stdout + result.stderr).contains("msp-python-launcher.py"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MSPPythonSubprocessShimTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
